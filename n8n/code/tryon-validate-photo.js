// n8n Code node "Validate Photo" in workflow "Try-On Bot · 2 · Photo & Try-On".
// Mode: Run Once for Each Item. Rejects photos the AI cannot use well.
const p = $json.photo;
const MAX_BYTES = 10 * 1024 * 1024;
const MIN_SIDE = 384;
const OK_TYPES = ['image/jpeg', 'image/png', 'image/webp'];
const maxMb = (MAX_BYTES / 1024 / 1024).toLocaleString('fa-IR');

const MESSAGES = {
  no_photo:   'عکسی دریافت نشد. لطفاً دوباره بفرستید.',
  bad_format: 'فقط عکس با فرمت JPG، PNG یا WEBP قابل قبول است.',
  too_large:  `حجم عکس بیشتر از ${maxMb} مگابایت است. لطفاً عکس کوچک‌تری بفرستید.`,
  too_small:  'کیفیت عکس خیلی پایین است. لطفاً عکس واضح‌تری بفرستید.',
};

let error = null;
if (!p?.file_id) error = 'no_photo';
else if (p.mime_type && !OK_TYPES.includes(p.mime_type)) error = 'bad_format';
// A missing size counts as too large: Telegram cannot download files over 20 MB.
else if ((p.file_size ?? Infinity) > MAX_BYTES) error = 'too_large';
else if (p.width && p.height && Math.min(p.width, p.height) < MIN_SIDE) error = 'too_small';

return {
  json: { ...$json, photo_valid: !error, photo_error: error, photo_error_text: MESSAGES[error] ?? null },
};
