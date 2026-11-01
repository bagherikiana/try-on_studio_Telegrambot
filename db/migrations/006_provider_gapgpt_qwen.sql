-- 006_provider_gapgpt_qwen: the AvalAI base tier blocks every image-editing model.
-- Switch the try-on to GapGPT (https://api.gapgpt.app/v1, no account tiers, balance only)
-- with gapgpt/qwen-image-2.1. The Call AI node (workflow 2) was moved to the gapGPT-v1 credential.
-- When the GapGPT balance allows, gpt-image-2.5-flare is the preferred model.
UPDATE tryon.settings
   SET value = '"gapgpt/qwen-image-2.1"'
 WHERE key = 'ai_model';

UPDATE tryon.settings
   SET description = 'Image model used for try-on (provider: GapGPT, see VTO 05 / Call AI)'
 WHERE key = 'ai_model';
