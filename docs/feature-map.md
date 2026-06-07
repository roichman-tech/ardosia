# Ardosia — by Roichman Tech
## Feature map — definitive v1

Consistent with `ardosia_schema.sql` v1. Every feature here has a backing column; every schema entity has a surface (or an explicit "no UI" decision).

---

## Customer (public catalog — no auth)

### Catalog (`/`)
- Lists active products (`is_active = true`, `deleted_at IS NULL`)
- **Sorting**
  - Alphabetical
  - Price — hidden when `tenant.show_product_prices = false` (never sort by invisible data)
  - Category
- **Filtering**
  - Name search — accent-insensitive (`f_unaccent`: "acucar" finds "açúcar")
  - Category
  - Tag
- **View modes:** grid / list
- **Product card**
  - Click → product detail page
  - "+" → add 1 to cart
  - `in_stock = false` → "Indisponível" badge, add-to-cart disabled, product stays visible
    - Hiding a product is `is_active`'s job, not stock's
  - Price visible IFF `tenant.show_product_prices AND NOT product.hide_price`

### Categories (`/categorias`)
- Active categories, A–Z, name search (accent-insensitive)

### Cart
- Min 1 per item; max = `product.max_quantity` (NULL = unlimited)
- Feature/option selection per item; `required` features must be chosen before add
- Option `price_delta_cents` reflected in displayed line price (when prices visible)
- One observation per **order** (`customer_note`) — not per item
- Client-side only; nothing persisted until checkout

### Checkout (WhatsApp handoff)
1. Persist `checkout_event` + `checkout_event_item` (snapshot by value)
2. Build message: `tenant.checkout_template` + items (name, qty, selected options, prices when visible) + customer note + total (when visible)
3. Redirect: `wa.me/{tenant.whatsapp_number}?text={url-encoded message}`
- **Message format is compact by default** (one line per item). Default encoded-length guard: if the encoded message exceeds ~1800 chars, drop per-item option detail to "ver opções no pedido #" referencing the persisted event. *Default, not decided — revisit if first merchants sell option-heavy products.*

---

## Merchant (dashboard — Clerk auth, `tenant_user` scoped)

MANAGE = list, create, edit, activate, deactivate, soft-delete.

- **Products:** MANAGE + stock toggle (`in_stock`) + `hide_price` + `max_quantity` + images (upload, reorder; position 0 = primary)
- **Features/options:** managed inside product editing (delta pricing; 0 = no change)
- **Categories:** MANAGE
- **Tags:** MANAGE
- **Brand identity:**
  - Business name, logo
  - Accent color (single, hex, contrast-validated on save)
  - Checkout message template
  - Price visibility kill-switch (`show_product_prices`)
  - WhatsApp number (E.164, merchant-editable — no Roichman intervention)
- **Received orders:** read-only list of `checkout_event` with items, totals, timestamps. No status workflow — fulfillment lives in WhatsApp, by design.

---

## Platform (Roichman Tech)

- **Tenant provisioning: documented script** (create tenant, set slug, link Clerk user, optional custom domain). No admin UI in MVP.
  - Trigger to build a panel: onboarding hurts twice in the same week.
- Clerk `user.deleted` webhook → soft-delete `tenant_user`
- Merchant offboarding: cascade delete from `tenant` (removes catalog, checkout log, storage objects via `storage_key` sweep)

---

## Cut from MVP (explicit, with reasoning)

| Feature | Reason | Return trigger |
|---|---|---|
| Promotions | Highest schema/pricing complexity, zero validation value for the core thesis | Merchant demand after launch; requires dates + stacking rules + price pipeline rework |
| Business hours | WhatsApp already communicates availability; merchant can note hours in checkout template | If customers repeatedly ask "are you open" |
| Range pricing | Contaminated sort, options, and message formatting | If "preço sob consulta" flag proves insufficient |
| Roichman admin panel | Script covers first ~10 merchants | Onboarding pain ×2/week |
| Plan gating | Single plan today; `plan` column is a trivial later migration | First paid tier defined |

---

## Open items (defaults encoded, not founder-decided)

1. wa.me message-length guard (~1800 encoded chars, fallback to compact format) — revisit with real merchant data
2. Category manual ordering (`sort_order`) — merchants will ask; not in v1 schema by choice