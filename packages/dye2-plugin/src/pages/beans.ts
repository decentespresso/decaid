import { pageShell } from "./layout";
import { beanListComponent } from "../components/bean-list";
import { beanFormComponent } from "../components/bean-form";
import { beanBatchListComponent } from "../components/bean-batch-list";
import { beanBatchFormComponent } from "../components/bean-batch-form";

const beanPageOrchestration = `
// Helper references
function beanList() { return document.querySelector('dye2-bean-list'); }
function beanForm() { return document.querySelector('dye2-bean-form'); }
function batchList() { return document.querySelector('dye2-bean-batch-list'); }
function batchForm() { return document.querySelector('dye2-bean-batch-form'); }

// --- Bean events ---

document.addEventListener('create-bean', () => {
  const form = beanForm();
  form.removeAttribute('bean-id');
  form.classList.remove('hidden');
  form.connectedCallback();
});

document.addEventListener('select-bean', (e) => {
  // Show batch list for this bean, hide bean list and form
  beanList().classList.add('hidden');
  beanForm().classList.add('hidden');
  batchForm().classList.add('hidden');

  const bl = batchList();
  bl.setAttribute('bean-id', e.detail.id);
  bl.classList.remove('hidden');
  bl.connectedCallback();
});

document.addEventListener('edit-bean', (e) => {
  const form = beanForm();
  form.setAttribute('bean-id', e.detail.id);
  form.classList.remove('hidden');
  form.connectedCallback();
});

document.addEventListener('bean-saved', () => {
  beanForm().classList.add('hidden');
  beanList().fetchBeans();
});

document.addEventListener('bean-cancelled', () => {
  beanForm().classList.add('hidden');
});

// --- Batch events ---

document.addEventListener('back-to-beans', () => {
  batchList().classList.add('hidden');
  batchForm().classList.add('hidden');
  beanList().classList.remove('hidden');
});

document.addEventListener('create-batch', (e) => {
  const form = batchForm();
  form.setAttribute('bean-id', e.detail.beanId);
  form.removeAttribute('batch-id');
  form.classList.remove('hidden');
  form.connectedCallback();
});

document.addEventListener('select-batch', (e) => {
  const form = batchForm();
  form.setAttribute('bean-id', e.detail.beanId);
  form.setAttribute('batch-id', e.detail.id);
  form.classList.remove('hidden');
  form.connectedCallback();
});

document.addEventListener('batch-saved', () => {
  batchForm().classList.add('hidden');
  batchList().fetchBatches();
});

document.addEventListener('batch-cancelled', () => {
  batchForm().classList.add('hidden');
});
`;

export function renderBeansPage(request: HttpRequest): HttpResponse {
  const content = `
    <dye2-bean-list></dye2-bean-list>
    <dye2-bean-form class="hidden"></dye2-bean-form>
    <dye2-bean-batch-list class="hidden"></dye2-bean-batch-list>
    <dye2-bean-batch-form class="hidden"></dye2-bean-batch-form>
  `;

  return {
    requestId: request.requestId,
    status: 200,
    headers: { "Content-Type": "text/html; charset=utf-8" },
    body: pageShell("Beans", content, [
      beanListComponent,
      beanFormComponent,
      beanBatchListComponent,
      beanBatchFormComponent,
      beanPageOrchestration,
    ]),
  };
}
