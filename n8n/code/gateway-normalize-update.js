// n8n Code node "Normalize Update" in workflow "Try-On Bot · 1 · Gateway & Onboarding".
// Mode: Run Once for Each Item. Turns any Telegram update into one flat shape.
const u = $json;
const m = u.message ?? {};
const msg = u.message ?? u.callback_query?.message ?? {};
const from = u.callback_query?.from ?? m.from ?? {};
const chat = msg.chat ?? {};

const asPhoto = (f, mime_type) => ({
  file_id: f.file_id, file_unique_id: f.file_unique_id,
  width: f.width ?? null, height: f.height ?? null, file_size: f.file_size, mime_type,
});

// Largest photo (Telegram always re-encodes compressed photos as JPEG), or an image sent as a file
const photo = m.photo?.length ? asPhoto(m.photo.at(-1), 'image/jpeg')
  : m.document?.mime_type?.startsWith('image/') ? asPhoto(m.document, m.document.mime_type)
  : null;

const text = m.text ?? m.caption ?? null;
const cmd = text?.match(/^\/(\w+)(?:@\w+)?\s*(.*)$/s);

const kind = u.callback_query ? 'callback'
  : photo ? 'photo'
  : cmd ? 'command'
  : text ? 'text'
  : 'unsupported';

return {
  json: {
    update_id: u.update_id,
    kind,
    telegram_user_id: from.id ?? null,
    chat_id: chat.id ?? null,
    username: from.username ?? null,
    first_name: from.first_name ?? null,
    language_code: from.language_code ?? null,
    is_private: chat.type === 'private',
    command: cmd ? cmd[1].toLowerCase() : null,
    command_args: cmd ? cmd[2].trim() : null,
    text,
    photo,
    callback_query_id: u.callback_query?.id ?? null,
    callback_data: u.callback_query?.data ?? null,
    message_id: msg.message_id ?? null,
    ignore: !from.id || !!from.is_bot || chat.type !== 'private',
  },
};
