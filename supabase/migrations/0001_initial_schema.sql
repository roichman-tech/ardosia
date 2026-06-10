-- ============================================================
-- ARDOSIA — by Roichman Tech
-- Definitive schema v1 (PostgreSQL / Supabase-compatible, portable)
-- ============================================================
-- Encoded decisions:
--   * Multi-tenancy: shared tables + tenant_id on EVERY table
--     (denormalized even where derivable via FK chain — keeps RLS
--     policies join-free and merchant offboarding a single cascade).
--   * Auth: Clerk. Identity lives in Clerk; access lives here
--     (tenant_user.auth_user_id is an opaque provider ID).
--   * Money: integer cents (BRL). No floats anywhere.
--   * Soft delete: deleted_at on all managed entities.
--     checkout_event* is an immutable log — no soft delete.
--   * Pricing: fixed price only. Option prices are deltas;
--     delta = 0 means "does not change price".
--   * Price visibility: tenant.show_product_prices is the global
--     kill-switch; product.hide_price is the per-product exception.
--     Visible IFF tenant.show_product_prices AND NOT product.hide_price.
--   * Observations: per-order (checkout_event.customer_note).
--   * max_quantity NULL = unlimited.
--   * Branding: single accent_color over fixed neutral base.
--   * Images: opaque storage_key; public URL is always derived
--     at read time, never persisted.
-- ============================================================

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM pg_extension e
    JOIN pg_namespace n ON n.oid = e.extnamespace
    WHERE e.extname = 'unaccent' AND n.nspname <> 'public'
  ) THEN
    ALTER EXTENSION unaccent SET SCHEMA public;
  END IF;
END $$;

CREATE EXTENSION IF NOT EXISTS unaccent WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS pgcrypto; -- gen_random_uuid()

-- unaccent() is STABLE, not IMMUTABLE — cannot be used in an
-- expression index directly. Immutable wrapper (standard fix):
CREATE OR REPLACE FUNCTION f_unaccent(text)
  RETURNS text
  LANGUAGE sql IMMUTABLE PARALLEL SAFE STRICT
AS $$ SELECT public.unaccent('public.unaccent', $1) $$;

-- updated_at trigger (attach to every table that has the column)
CREATE OR REPLACE FUNCTION set_updated_at()
  RETURNS trigger LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END $$;

-- ============================================================
-- TENANT
-- ============================================================
CREATE TABLE tenant (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name                text NOT NULL,
  slug                text NOT NULL,
  custom_domain       text,
  whatsapp_number     text NOT NULL,           -- E.164: +5588999999999
  logo_storage_key    text,
  accent_color        text NOT NULL DEFAULT '#0A0A0A',
  show_product_prices boolean NOT NULL DEFAULT true,  -- global kill-switch
  checkout_template   text NOT NULL DEFAULT '',
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  deleted_at          timestamptz,

  CONSTRAINT tenant_slug_format
    CHECK (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  CONSTRAINT tenant_whatsapp_e164
    CHECK (whatsapp_number ~ '^\+[1-9][0-9]{7,14}$'),
  CONSTRAINT tenant_accent_hex
    CHECK (accent_color ~ '^#[0-9A-Fa-f]{6}$')
);

CREATE UNIQUE INDEX uq_tenant_slug
  ON tenant (slug) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX uq_tenant_custom_domain
  ON tenant (custom_domain) WHERE deleted_at IS NULL AND custom_domain IS NOT NULL;

CREATE TRIGGER trg_tenant_updated BEFORE UPDATE ON tenant
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================
-- TENANT_USER — maps auth provider identity -> tenant access.
-- Provider-agnostic: auth_user_id is the Clerk user ID today,
-- anything else tomorrow. Do NOT use Clerk Organizations.
-- ============================================================
CREATE TABLE tenant_user (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
  auth_user_id  text NOT NULL,                 -- opaque provider ID (Clerk)
  role          text NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz,                   -- set via Clerk user.deleted webhook

  CONSTRAINT tenant_user_role CHECK (role IN ('owner'))
);

CREATE UNIQUE INDEX uq_tenant_user
  ON tenant_user (tenant_id, auth_user_id) WHERE deleted_at IS NULL;
CREATE INDEX ix_tenant_user_auth
  ON tenant_user (auth_user_id) WHERE deleted_at IS NULL;

-- ============================================================
-- PRODUCT
-- ============================================================
CREATE TABLE product (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     uuid NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
  name          text NOT NULL,
  description   text NOT NULL DEFAULT '',
  price_cents   bigint NOT NULL,
  hide_price    boolean NOT NULL DEFAULT false, -- exception to kill-switch
  max_quantity  integer,                        -- NULL = unlimited
  in_stock      boolean NOT NULL DEFAULT true,  -- "out today"
  is_active     boolean NOT NULL DEFAULT true,  -- "exists in catalog"
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  deleted_at    timestamptz,

  CONSTRAINT product_price_nonneg CHECK (price_cents >= 0),
  CONSTRAINT product_maxqty_pos   CHECK (max_quantity IS NULL OR max_quantity >= 1)
);

-- Catalog listing path
CREATE INDEX ix_product_catalog
  ON product (tenant_id, is_active) WHERE deleted_at IS NULL;
-- Accent-insensitive name search ("acucar" finds "açúcar")
CREATE INDEX ix_product_name_search
  ON product (tenant_id, f_unaccent(lower(name)) text_pattern_ops)
  WHERE deleted_at IS NULL;

CREATE TRIGGER trg_product_updated BEFORE UPDATE ON product
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================
-- PRODUCT_IMAGE — position 0 = primary image (by convention)
-- ============================================================
CREATE TABLE product_image (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id    uuid NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
  product_id   uuid NOT NULL REFERENCES product(id) ON DELETE CASCADE,
  storage_key  text NOT NULL,                  -- never persist public URL
  position     integer NOT NULL DEFAULT 0,
  created_at   timestamptz NOT NULL DEFAULT now(),

  -- DEFERRABLE so reordering (swap positions) works in one tx
  CONSTRAINT uq_product_image_position
    UNIQUE (product_id, position) DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX ix_product_image_product
  ON product_image (product_id, position);

-- ============================================================
-- FEATURE / OPTION (product variations)
-- ============================================================
CREATE TABLE feature (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
  product_id  uuid NOT NULL REFERENCES product(id) ON DELETE CASCADE,
  name        text NOT NULL,
  required    boolean NOT NULL DEFAULT false,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz
);

CREATE INDEX ix_feature_product
  ON feature (product_id) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_feature_updated BEFORE UPDATE ON feature
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE option (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id         uuid NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
  feature_id        uuid NOT NULL REFERENCES feature(id) ON DELETE CASCADE,
  name              text NOT NULL,
  price_delta_cents bigint NOT NULL DEFAULT 0, -- 0 = no price change
  is_active         boolean NOT NULL DEFAULT true,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  deleted_at        timestamptz
);

CREATE INDEX ix_option_feature
  ON option (feature_id) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_option_updated BEFORE UPDATE ON option
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ============================================================
-- CATEGORY / TAG  (+ junctions)
-- ============================================================
CREATE TABLE category (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
  name        text NOT NULL,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz
);

-- Per-tenant uniqueness; partial so a deleted name can be recreated
CREATE UNIQUE INDEX uq_category_name
  ON category (tenant_id, f_unaccent(lower(name))) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_category_updated BEFORE UPDATE ON category
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE tag (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   uuid NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
  name        text NOT NULL,
  is_active   boolean NOT NULL DEFAULT true,
  created_at  timestamptz NOT NULL DEFAULT now(),
  updated_at  timestamptz NOT NULL DEFAULT now(),
  deleted_at  timestamptz
);

CREATE UNIQUE INDEX uq_tag_name
  ON tag (tenant_id, f_unaccent(lower(name))) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_tag_updated BEFORE UPDATE ON tag
  FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- Junctions: hard delete (no deleted_at); tenant_id kept for RLS
CREATE TABLE product_category (
  tenant_id    uuid NOT NULL REFERENCES tenant(id)   ON DELETE CASCADE,
  product_id   uuid NOT NULL REFERENCES product(id)  ON DELETE CASCADE,
  category_id  uuid NOT NULL REFERENCES category(id) ON DELETE CASCADE,
  PRIMARY KEY (product_id, category_id)
);
CREATE INDEX ix_product_category_cat ON product_category (category_id);

CREATE TABLE product_tag (
  tenant_id   uuid NOT NULL REFERENCES tenant(id)  ON DELETE CASCADE,
  product_id  uuid NOT NULL REFERENCES product(id) ON DELETE CASCADE,
  tag_id      uuid NOT NULL REFERENCES tag(id)     ON DELETE CASCADE,
  PRIMARY KEY (product_id, tag_id)
);
CREATE INDEX ix_product_tag_tag ON product_tag (tag_id);

-- ============================================================
-- CHECKOUT EVENT — immutable log of WhatsApp handoffs.
-- Snapshot by value: names/prices copied, never joined.
-- No deleted_at; removed only on merchant offboarding (cascade).
-- ============================================================
CREATE TABLE checkout_event (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
  total_amount_cents bigint,            -- NULL when prices hidden
  message_text       text NOT NULL,      -- exact generated message
  customer_note      text,               -- per-order observation
  created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX ix_checkout_event_tenant
  ON checkout_event (tenant_id, created_at DESC);

CREATE TABLE checkout_event_item (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id          uuid NOT NULL REFERENCES tenant(id) ON DELETE CASCADE,
  checkout_event_id  uuid NOT NULL REFERENCES checkout_event(id) ON DELETE CASCADE,
  product_id         uuid REFERENCES product(id) ON DELETE SET NULL, -- best-effort link
  product_name       text NOT NULL,      -- SNAPSHOT
  quantity           integer NOT NULL,
  unit_price_cents   bigint,            -- SNAPSHOT; NULL when hidden
  selected_options   jsonb NOT NULL DEFAULT '[]'::jsonb,
  -- shape: [{ "feature": "Tamanho", "option": "G", "price_delta_cents": 500 }]

  CONSTRAINT cei_quantity_pos CHECK (quantity >= 1)
);

CREATE INDEX ix_cei_event   ON checkout_event_item (checkout_event_id);
CREATE INDEX ix_cei_product ON checkout_event_item (tenant_id, product_id);

-- ============================================================
-- RLS — wrapper pattern (portability boundary).
-- All policies depend ONLY on current_tenant_id(). Today it reads
-- the Clerk JWT claim via Supabase third-party auth; migrating off
-- Supabase = reimplement this ONE function (e.g. read
-- current_setting('app.tenant_id') set by the backend).
-- ============================================================
CREATE OR REPLACE FUNCTION current_tenant_id()
  RETURNS uuid LANGUAGE sql STABLE
AS $$
  SELECT tu.tenant_id
  FROM tenant_user tu
  WHERE tu.auth_user_id = (auth.jwt() ->> 'sub')
    AND tu.deleted_at IS NULL
  LIMIT 1
$$;

-- Enable + policy on every tenant-scoped table (repeat per table):
-- ALTER TABLE product ENABLE ROW LEVEL SECURITY;
-- CREATE POLICY product_tenant_isolation ON product
--   USING (tenant_id = current_tenant_id());
--
-- Public catalog reads go through the backend (or a restricted
-- anon policy filtered by tenant slug) — decide at API layer.