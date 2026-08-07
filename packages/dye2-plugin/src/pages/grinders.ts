import { pageShell } from "./layout";
import { grinderListComponent } from "../components/grinder-list";
import { grinderFormComponent } from "../components/grinder-form";

const grinderPageOrchestration = `
document.addEventListener('create-grinder', () => {
  const form = document.querySelector('dye2-grinder-form');
  form.removeAttribute('grinder-id');
  form.classList.remove('hidden');
  form.connectedCallback();
});
document.addEventListener('select-grinder', (e) => {
  const form = document.querySelector('dye2-grinder-form');
  form.setAttribute('grinder-id', e.detail.id);
  form.classList.remove('hidden');
  form.connectedCallback();
});
document.addEventListener('grinder-saved', () => {
  document.querySelector('dye2-grinder-form').classList.add('hidden');
  document.querySelector('dye2-grinder-list').fetchGrinders();
});
document.addEventListener('grinder-cancelled', () => {
  document.querySelector('dye2-grinder-form').classList.add('hidden');
});
`;

export function renderGrindersPage(request: HttpRequest): HttpResponse {
  const content = `
    <dye2-grinder-list></dye2-grinder-list>
    <dye2-grinder-form class="hidden"></dye2-grinder-form>
  `;

  return {
    requestId: request.requestId,
    status: 200,
    headers: { "Content-Type": "text/html; charset=utf-8" },
    body: pageShell("Grinders", content, [
      grinderListComponent,
      grinderFormComponent,
      grinderPageOrchestration,
    ]),
  };
}
