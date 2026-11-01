// n8n Code node "Pack Images" in workflow "Try-On Bot · 2 · Photo & Try-On".
// Mode: Run Once for Each Item. Puts both downloaded photos on one item
// (binary "person" and "garment") so one HTTP request can send both to the image provider.
const person = $('Download Person').item.binary?.data;
const garment = $input.item.binary?.data;
if (!person || !garment) {
  throw new Error(`Missing image: person=${!!person}, garment=${!!garment}`);
}

const job = $('Start Job').item.json;
return {
  json: { job_id: job.job_id, model: job.model, prompt_version: job.prompt_version },
  binary: { person, garment },
};
