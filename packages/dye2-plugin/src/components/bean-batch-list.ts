export const beanBatchListComponent = `
class Dye2BeanBatchList extends HTMLElement {
  constructor() {
    super();
    this._batches = [];
    this._beanId = null;
    this._loading = false;
    this._showArchived = false;
  }

  static get observedAttributes() {
    return ['bean-id'];
  }

  attributeChangedCallback(name, oldVal, newVal) {
    if (name === 'bean-id') {
      this._beanId = newVal;
    }
  }

  connectedCallback() {
    this._beanId = this.getAttribute('bean-id') || null;
    if (this._beanId) {
      this.fetchBatches();
    } else {
      this.render();
    }
  }

  async fetchBatches() {
    if (!this._beanId) return;
    this._loading = true;
    this.render();
    try {
      const params = this._showArchived ? '?includeArchived=true' : '';
      const res = await fetch('/api/v1/beans/' + this._beanId + '/batches' + params);
      if (!res.ok) throw new Error('HTTP ' + res.status);
      this._batches = await res.json();
      this._loading = false;
      this.render();
    } catch (err) {
      this._loading = false;
      this.innerHTML = '<p style="color: #ff6b6b;">Failed to load batches: ' + err.message + '</p>';
    }
  }

  toggleArchived() {
    this._showArchived = !this._showArchived;
    this.fetchBatches();
  }

  _formatDate(iso) {
    if (!iso) return '';
    try {
      const d = new Date(iso);
      return d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
    } catch (e) {
      return iso;
    }
  }

  _esc(val) {
    if (val == null) return '';
    return String(val).replace(/&/g,'&amp;').replace(/"/g,'&quot;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }

  render() {
    if (this._loading) {
      this.innerHTML = '<div class="card"><p class="text-muted">Loading batches...</p></div>';
      return;
    }

    if (!this._beanId) {
      this.innerHTML = '<p class="text-muted">No bean selected.</p>';
      return;
    }

    const batches = this._batches;
    this.innerHTML = \`
      <div class="flex-between mb-8">
        <div class="flex">
          <button data-action="back">&larr; Back to beans</button>
          <h2 style="margin:0;">Batches</h2>
          <button data-action="edit-bean">Edit Bean</button>
        </div>
        <div class="flex">
          <label class="flex" style="cursor:pointer;">
            <input type="checkbox" \${this._showArchived ? 'checked' : ''} style="width:auto;" />
            <span class="text-small">Show archived</span>
          </label>
          <button class="primary" data-action="create">+ Add Batch</button>
        </div>
      </div>
      \${batches.length === 0
        ? '<p class="text-muted">No batches yet. Add your first batch!</p>'
        : batches.map(b => \`
          <div class="card" data-batch-id="\${b.id}">
            <div class="flex-between">
              <div>
                \${b.roastDate ? '<strong>Roasted: ' + this._formatDate(b.roastDate) + '</strong>' : '<strong>Batch</strong>'}
              </div>
              <div class="flex">
                \${b.roastLevel ? '<span class="tag">' + this._esc(b.roastLevel) + '</span>' : ''}
                \${b.frozen ? '<span class="tag">frozen</span>' : ''}
                \${b.archived ? '<span class="tag">archived</span>' : ''}
              </div>
            </div>
            <div class="flex text-small text-muted mt-8" style="flex-wrap:wrap;">
              \${b.weight != null ? '<span>' + (b.weightRemaining != null ? b.weightRemaining + 'g / ' : '') + b.weight + 'g</span>' : ''}
              \${b.price != null ? '<span>' + (b.currency || '') + ' ' + b.price.toFixed(2) + '</span>' : ''}
              \${b.qualityScore != null ? '<span>Score: ' + b.qualityScore + '</span>' : ''}
            </div>
            \${b.notes ? '<div class="text-small text-muted mt-8" style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">' + this._esc(b.notes) + '</div>' : ''}
          </div>
        \`).join('')
      }
    \`;

    // Event listeners
    const checkbox = this.querySelector('input[type="checkbox"]');
    if (checkbox) checkbox.addEventListener('change', () => this.toggleArchived());

    const backBtn = this.querySelector('[data-action="back"]');
    if (backBtn) backBtn.addEventListener('click', () => {
      this.dispatchEvent(new CustomEvent('back-to-beans', { bubbles: true }));
    });

    const editBeanBtn = this.querySelector('[data-action="edit-bean"]');
    if (editBeanBtn) editBeanBtn.addEventListener('click', () => {
      this.dispatchEvent(new CustomEvent('edit-bean', { detail: { id: this._beanId }, bubbles: true }));
    });

    const createBtn = this.querySelector('[data-action="create"]');
    if (createBtn) createBtn.addEventListener('click', () => {
      this.dispatchEvent(new CustomEvent('create-batch', { detail: { beanId: this._beanId }, bubbles: true }));
    });

    this.querySelectorAll('[data-batch-id]').forEach(card => {
      card.style.cursor = 'pointer';
      card.addEventListener('click', () => {
        const id = card.getAttribute('data-batch-id');
        this.dispatchEvent(new CustomEvent('select-batch', { detail: { id, beanId: this._beanId }, bubbles: true }));
      });
    });
  }
}
customElements.define('dye2-bean-batch-list', Dye2BeanBatchList);
`;
