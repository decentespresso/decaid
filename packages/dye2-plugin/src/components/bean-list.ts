export const beanListComponent = `
class Dye2BeanList extends HTMLElement {
  constructor() {
    super();
    this._beans = [];
    this._showArchived = false;
  }

  _esc(val) {
    if (val == null) return '';
    return String(val).replace(/&/g,'&amp;').replace(/"/g,'&quot;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }

  connectedCallback() {
    this.render();
    this.fetchBeans();
  }

  async fetchBeans() {
    try {
      const params = this._showArchived ? '?includeArchived=true' : '';
      const res = await fetch('/api/v1/beans' + params);
      if (!res.ok) throw new Error('HTTP ' + res.status);
      this._beans = await res.json();
      this.render();
    } catch (err) {
      this.innerHTML = '<p style="color: #ff6b6b;">Failed to load beans: ' + err.message + '</p>';
    }
  }

  toggleArchived() {
    this._showArchived = !this._showArchived;
    this.fetchBeans();
  }

  render() {
    const beans = this._beans;
    this.innerHTML = \`
      <div class="flex-between mb-8">
        <h1>Beans</h1>
        <div class="flex">
          <label class="flex" style="cursor:pointer;">
            <input type="checkbox" \${this._showArchived ? 'checked' : ''} style="width:auto;" />
            <span class="text-small">Show archived</span>
          </label>
          <button class="primary" data-action="create">+ Add Bean</button>
        </div>
      </div>
      \${beans.length === 0
        ? '<p class="text-muted">No beans yet. Add your first coffee!</p>'
        : beans.map(bean => \`
          <div class="card" data-bean-id="\${bean.id}">
            <div class="flex-between">
              <div>
                <strong>\${this._esc(bean.name) || 'Unnamed'}</strong>
                <span class="text-muted"> by \${this._esc(bean.roaster) || 'Unknown roaster'}</span>
              </div>
              <div class="flex">
                \${bean.archived ? '<span class="tag">archived</span>' : ''}
                \${bean.country ? '<span class="tag">' + this._esc(bean.country) + '</span>' : ''}
                \${bean.processing ? '<span class="tag">' + this._esc(bean.processing) + '</span>' : ''}
                <button class="icon-btn" data-edit-bean-id="\${bean.id}" title="Edit bean">&hellip;</button>
              </div>
            </div>
            \${bean.variety && bean.variety.length ? '<div class="text-small text-muted mt-8">' + bean.variety.map(v => this._esc(v)).join(', ') + '</div>' : ''}
          </div>
        \`).join('')
      }
    \`;

    // Event listeners
    const checkbox = this.querySelector('input[type="checkbox"]');
    if (checkbox) checkbox.addEventListener('change', () => this.toggleArchived());

    const createBtn = this.querySelector('[data-action="create"]');
    if (createBtn) createBtn.addEventListener('click', () => {
      this.dispatchEvent(new CustomEvent('create-bean', { bubbles: true }));
    });

    this.querySelectorAll('[data-edit-bean-id]').forEach(btn => {
      btn.addEventListener('click', (e) => {
        e.stopPropagation();
        const id = btn.getAttribute('data-edit-bean-id');
        this.dispatchEvent(new CustomEvent('edit-bean', { detail: { id }, bubbles: true }));
      });
    });

    this.querySelectorAll('[data-bean-id]').forEach(card => {
      card.style.cursor = 'pointer';
      card.addEventListener('click', () => {
        const id = card.getAttribute('data-bean-id');
        this.dispatchEvent(new CustomEvent('select-bean', { detail: { id }, bubbles: true }));
      });
    });
  }
}
customElements.define('dye2-bean-list', Dye2BeanList);
`;
