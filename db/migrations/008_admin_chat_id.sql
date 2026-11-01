-- 008_admin_chat_id: Telegram chat that receives admin alerts (e.g. the image
-- provider rejecting requests for balance or account-tier reasons).
-- Seeded empty on purpose: a real chat id is personal data and must not live in git.
-- Set it per database with:  npm run db:set admin_chat_id <telegram chat id>
-- While it is empty, admin alerts are simply skipped.
INSERT INTO tryon.settings (key, value, description)
VALUES ('admin_chat_id', '""', 'Telegram chat id that receives admin alerts')
ON CONFLICT (key) DO NOTHING;
