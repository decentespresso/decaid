export const beanBatchFormComponent = `
class Dye2BeanBatchForm extends HTMLElement {
  constructor() {
    super();
    this._beanId = null;
    this._batchId = null;
    this._loading = false;
    this._error = null;
    this._data = {};
  }

  static get observedAttributes() {
    return ['bean-id', 'batch-id'];
  }

  attributeChangedCallback(name, oldVal, newVal) {
    if (name === 'bean-id') this._beanId = newVal;
    if (name === 'batch-id') this._batchId = newVal;
  }

  connectedCallback() {
    this._beanId = this.getAttribute('bean-id') || null;
    this._batchId = this.getAttribute('batch-id') || null;
    this._data = {};
    this._error = null;
    if (this._batchId) {
      this._loadBatch();
    } else {
      this.render();
    }
  }

  async _loadBatch() {
    this._loading = true;
    this.render();
    try {
      const res = await fetch('/api/v1/bean-batches/' + this._batchId);
      if (!res.ok) throw new Error('HTTP ' + res.status);
      this._data = await res.json();
      this._loading = false;
      this.render();
    } catch (err) {
      this._loading = false;
      this._error = 'Failed to load batch: ' + err.message;
      this.render();
    }
  }

  _val(field) {
    return this._data[field] != null ? this._data[field] : '';
  }

  _dateVal(field) {
    const v = this._data[field];
    if (!v) return '';
    // Return YYYY-MM-DD for date input
    try {
      return new Date(v).toISOString().split('T')[0];
    } catch (e) {
      return v;
    }
  }

  _esc(val) {
    if (val == null) return '';
    return String(val).replace(/&/g,'&amp;').replace(/"/g,'&quot;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }

  render() {
    if (this._loading) {
      this.innerHTML = '<div class="card"><p class="text-muted">Loading batch...</p></div>';
      return;
    }
    if (this._error) {
      this.innerHTML = '<div class="card"><p style="color:#ff6b6b;">' + this._error + '</p>'
        + '<button data-action="cancel">Back</button></div>';
      this.querySelector('[data-action="cancel"]').addEventListener('click', () => this._cancel());
      return;
    }

    const isEdit = !!this._batchId;
    const roastLevel = this._val('roastLevel');

    this.innerHTML = \`
      <div class="card">
        <h2>\${isEdit ? 'Edit Batch' : 'New Batch'}</h2>
        <form id="batch-form">
          <div class="grid grid-2 mb-8">
            <div>
              <label class="text-small text-muted">Roast Date</label>
              <input type="date" name="roastDate" value="\${this._esc(this._dateVal('roastDate'))}" />
            </div>
            <div>
              <label class="text-small text-muted">Roast Level</label>
              <select name="roastLevel">
                <option value="">-- select --</option>
                <option value="light" \${roastLevel === 'light' ? 'selected' : ''}>Light</option>
                <option value="medium" \${roastLevel === 'medium' ? 'selected' : ''}>Medium</option>
                <option value="medium-dark" \${roastLevel === 'medium-dark' ? 'selected' : ''}>Medium-Dark</option>
                <option value="dark" \${roastLevel === 'dark' ? 'selected' : ''}>Dark</option>
              </select>
            </div>
          </div>
          <div class="grid grid-2 mb-8">
            <div>
              <label class="text-small text-muted">Weight (grams)</label>
              <input type="number" name="weight" min="0" step="1" value="\${this._esc(this._val('weight'))}" placeholder="e.g. 250" />
            </div>
            <div>
              <label class="text-small text-muted">Quality / Cupping Score</label>
              <input type="number" name="qualityScore" min="0" max="100" step="0.1" value="\${this._esc(this._val('qualityScore'))}" placeholder="e.g. 85.5" />
            </div>
          </div>
          <div class="grid grid-2 mb-8">
            <div>
              <label class="text-small text-muted">Price</label>
              <input type="number" name="price" min="0" step="0.01" value="\${this._esc(this._val('price'))}" placeholder="e.g. 18.50" />
            </div>
            <div>
              <label class="text-small text-muted">Currency</label>
              <input name="currency" value="\${this._esc(this._val('currency'))}" placeholder="e.g. USD, EUR" />
            </div>
          </div>
          <div class="grid grid-2 mb-8">
            <div>
              <label class="text-small text-muted">Buy Date</label>
              <input type="date" name="buyDate" value="\${this._esc(this._dateVal('buyDate'))}" />
            </div>
            <div>
              <label class="text-small text-muted">Open Date</label>
              <input type="date" name="openDate" value="\${this._esc(this._dateVal('openDate'))}" />
            </div>
          </div>
          <div class="grid grid-2 mb-8">
            <div>
              <label class="text-small text-muted">Harvest Date</label>
              <input type="date" name="harvestDate" value="\${this._esc(this._dateVal('harvestDate'))}" />
            </div>
            <div>
              <label class="text-small text-muted">Best Before Date</label>
              <input type="date" name="bestBeforeDate" value="\${this._esc(this._dateVal('bestBeforeDate'))}" />
            </div>
          </div>
          <div class="mb-8">
            <label class="text-small text-muted">Notes</label>
            <textarea name="notes" rows="3" placeholder="Batch notes...">\${this._esc(this._val('notes'))}</textarea>
          </div>
          <div class="flex">
            <button type="submit" class="primary">\${isEdit ? 'Save' : 'Create'}</button>
            <button type="button" data-action="cancel">Cancel</button>
          </div>
        </form>
      </div>
    \`;

    // Cancel button
    this.querySelector('[data-action="cancel"]').addEventListener('click', () => this._cancel());

    // Form submit
    this.querySelector('#batch-form').addEventListener('submit', (e) => {
      e.preventDefault();
      this._submit();
    });
  }

  _cancel() {
    this.dispatchEvent(new CustomEvent('batch-cancelled', { bubbles: true }));
  }

  async _submit() {
    const form = this.querySelector('#batch-form');
    const fd = new FormData(form);
    const body = {};

    // Date fields
    const dateFields = ['roastDate', 'harvestDate', 'buyDate', 'openDate', 'bestBeforeDate'];
    for (const key of dateFields) {
      const v = fd.get(key);
      if (v) body[key] = v;
    }

    // String fields
    const strFields = ['roastLevel', 'currency', 'notes'];
    for (const key of strFields) {
      const v = fd.get(key);
      if (v) body[key] = v;
    }

    // Number fields
    const numFields = ['weight', 'price', 'qualityScore'];
    for (const key of numFields) {
      const v = fd.get(key);
      if (v !== '' && v != null) body[key] = parseFloat(v);
    }

    try {
      let url, method;
      if (this._batchId) {
        url = '/api/v1/bean-batches/' + this._batchId;
        method = 'PUT';
      } else {
        url = '/api/v1/beans/' + this._beanId + '/batches';
        method = 'POST';
      }
      const res = await fetch(url, {
        method,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (!res.ok) {
        const text = await res.text();
        throw new Error('HTTP ' + res.status + ': ' + text);
      }
      this.dispatchEvent(new CustomEvent('batch-saved', { bubbles: true }));
    } catch (err) {
      this._error = 'Save failed: ' + err.message;
      this.render();
    }
  }
}
customElements.define('dye2-bean-batch-form', Dye2BeanBatchForm);
`;
