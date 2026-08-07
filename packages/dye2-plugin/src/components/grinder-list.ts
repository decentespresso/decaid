export const grinderListComponent = `
class Dye2GrinderList extends HTMLElement {
  constructor() {
    super();
    this._grinders = [];
    this._showArchived = false;
  }

  _esc(val) {
    if (val == null) return '';
    return String(val).replace(/&/g,'&amp;').replace(/"/g,'&quot;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }

  connectedCallback() {
    this.render();
    this.fetchGrinders();
  }

  async fetchGrinders() {
    try {
      const params = this._showArchived ? '?includeArchived=true' : '';
      const res = await fetch('/api/v1/grinders' + params);
      if (!res.ok) throw new Error('HTTP ' + res.status);
      this._grinders = await res.json();
      this.render();
    } catch (err) {
      this.innerHTML = '<p style="color: #ff6b6b;">Failed to load grinders: ' + err.message + '</p>';
    }
  }

  toggleArchived() {
    this._showArchived = !this._showArchived;
    this.fetchGrinders();
  }

  render() {
    const grinders = this._grinders;
    this.innerHTML = \`
      <div class="flex-between mb-8">
        <h1>Grinders</h1>
        <div class="flex">
          <label class="flex" style="cursor:pointer;">
            <input type="checkbox" \${this._showArchived ? 'checked' : ''} style="width:auto;" />
            <span class="text-small">Show archived</span>
          </label>
          <button class="primary" data-action="create">+ Add Grinder</button>
        </div>
      </div>
      \${grinders.length === 0
        ? '<p class="text-muted">No grinders yet. Add your first grinder!</p>'
        : grinders.map(g => \`
          <div class="card" data-grinder-id="\${g.id}">
            <div class="flex-between">
              <div>
                <strong>\${this._esc(g.model) || 'Unnamed'}</strong>
              </div>
              <div class="flex">
                \${g.archived ? '<span class="tag">archived</span>' : ''}
                \${g.settingType ? '<span class="tag">' + this._esc(g.settingType) + '</span>' : ''}
              </div>
            </div>
            <div class="flex text-small text-muted mt-8">
              \${g.burrs ? '<span>Burrs: ' + this._esc(g.burrs) + '</span>' : ''}
              \${g.burrType ? '<span>Type: ' + this._esc(g.burrType) + '</span>' : ''}
              \${g.burrSize ? '<span>Size: ' + this._esc(g.burrSize) + 'mm</span>' : ''}
            </div>
            \${g.notes ? '<div class="text-small text-muted mt-8">' + this._esc(g.notes) + '</div>' : ''}
          </div>
        \`).join('')
      }
    \`;

    // Event listeners
    const checkbox = this.querySelector('input[type="checkbox"]');
    if (checkbox) checkbox.addEventListener('change', () => this.toggleArchived());

    const createBtn = this.querySelector('[data-action="create"]');
    if (createBtn) createBtn.addEventListener('click', () => {
      this.dispatchEvent(new CustomEvent('create-grinder', { bubbles: true }));
    });

    this.querySelectorAll('[data-grinder-id]').forEach(card => {
      card.style.cursor = 'pointer';
      card.addEventListener('click', () => {
        const id = card.getAttribute('data-grinder-id');
        this.dispatchEvent(new CustomEvent('select-grinder', { detail: { id }, bubbles: true }));
      });
    });
  }
}
customElements.define('dye2-grinder-list', Dye2GrinderList);
`;
