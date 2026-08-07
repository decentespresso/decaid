export const beanFormComponent = `
class Dye2BeanForm extends HTMLElement {
  constructor() {
    super();
    this._beanId = null;
    this._loading = false;
    this._error = null;
    this._data = {};
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
    this._data = {};
    this._error = null;
    if (this._beanId) {
      this._loadBean();
    } else {
      this.render();
    }
  }

  async _loadBean() {
    this._loading = true;
    this.render();
    try {
      const res = await fetch('/api/v1/beans/' + this._beanId);
      if (!res.ok) throw new Error('HTTP ' + res.status);
      this._data = await res.json();
      this._loading = false;
      this.render();
    } catch (err) {
      this._loading = false;
      this._error = 'Failed to load bean: ' + err.message;
      this.render();
    }
  }

  _val(field) {
    return this._data[field] != null ? this._data[field] : '';
  }

  render() {
    if (this._loading) {
      this.innerHTML = '<div class="card"><p class="text-muted">Loading bean...</p></div>';
      return;
    }
    if (this._error) {
      this.innerHTML = '<div class="card"><p style="color:#ff6b6b;">' + this._error + '</p>'
        + '<button data-action="cancel">Back</button></div>';
      this.querySelector('[data-action="cancel"]').addEventListener('click', () => this._cancel());
      return;
    }

    const isEdit = !!this._beanId;
    const variety = Array.isArray(this._data.variety) ? this._data.variety.join(', ') : (this._data.variety || '');
    const altitude = Array.isArray(this._data.altitude) ? this._data.altitude.join('-') : (this._data.altitude || '');
    const decaf = this._data.decaf || false;

    this.innerHTML = \`
      <div class="card">
        <h2>\${isEdit ? 'Edit Bean' : 'New Bean'}</h2>
        <form id="bean-form">
          <div class="grid grid-2 mb-8">
            <div>
              <label class="text-small text-muted">Roaster *</label>
              <input name="roaster" required value="\${this._esc(this._val('roaster'))}" placeholder="Roaster name" />
            </div>
            <div>
              <label class="text-small text-muted">Name *</label>
              <input name="name" required value="\${this._esc(this._val('name'))}" placeholder="Bean name" />
            </div>
          </div>
          <div class="grid grid-2 mb-8">
            <div>
              <label class="text-small text-muted">Country</label>
              <input name="country" value="\${this._esc(this._val('country'))}" placeholder="Country of origin" />
            </div>
            <div>
              <label class="text-small text-muted">Region</label>
              <input name="region" value="\${this._esc(this._val('region'))}" placeholder="Region" />
            </div>
          </div>
          <div class="grid grid-2 mb-8">
            <div>
              <label class="text-small text-muted">Producer</label>
              <input name="producer" value="\${this._esc(this._val('producer'))}" placeholder="Producer / Farm" />
            </div>
            <div>
              <label class="text-small text-muted">Species</label>
              <input name="species" value="\${this._esc(this._val('species'))}" placeholder="e.g. arabica" />
            </div>
          </div>
          <div class="grid grid-2 mb-8">
            <div>
              <label class="text-small text-muted">Processing</label>
              <input name="processing" value="\${this._esc(this._val('processing'))}" placeholder="e.g. washed, natural, honey" />
            </div>
            <div>
              <label class="text-small text-muted">Variety (comma-separated)</label>
              <input name="variety" value="\${this._esc(variety)}" placeholder="e.g. Bourbon, Typica" />
            </div>
          </div>
          <div class="grid grid-2 mb-8">
            <div>
              <label class="text-small text-muted">Altitude (e.g. 1500-1800)</label>
              <input name="altitude" value="\${this._esc(altitude)}" placeholder="min-max in meters" />
            </div>
            <div class="flex" style="align-items:flex-end;padding-bottom:2px;">
              <label class="flex" style="cursor:pointer;">
                <input type="checkbox" name="decaf" \${decaf ? 'checked' : ''} style="width:auto;" />
                <span class="text-small">Decaf</span>
              </label>
            </div>
          </div>
          <div class="mb-8 \${decaf ? '' : 'hidden'}" id="decaf-process-row">
            <label class="text-small text-muted">Decaf Process</label>
            <input name="decafProcess" value="\${this._esc(this._val('decafProcess'))}" placeholder="e.g. Swiss Water, CO2" />
          </div>
          <div class="mb-8">
            <label class="text-small text-muted">Notes</label>
            <textarea name="notes" rows="3" placeholder="Tasting notes, comments...">\${this._esc(this._val('notes'))}</textarea>
          </div>
          <div class="flex">
            <button type="submit" class="primary">\${isEdit ? 'Save' : 'Create'}</button>
            <button type="button" data-action="cancel">Cancel</button>
          </div>
        </form>
      </div>
    \`;

    // Toggle decaf process visibility
    const decafCheckbox = this.querySelector('input[name="decaf"]');
    const decafRow = this.querySelector('#decaf-process-row');
    if (decafCheckbox && decafRow) {
      decafCheckbox.addEventListener('change', () => {
        decafRow.classList.toggle('hidden', !decafCheckbox.checked);
      });
    }

    // Cancel button
    this.querySelector('[data-action="cancel"]').addEventListener('click', () => this._cancel());

    // Form submit
    this.querySelector('#bean-form').addEventListener('submit', (e) => {
      e.preventDefault();
      this._submit();
    });
  }

  _esc(val) {
    if (val == null) return '';
    return String(val).replace(/&/g,'&amp;').replace(/"/g,'&quot;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }

  _cancel() {
    this.dispatchEvent(new CustomEvent('bean-cancelled', { bubbles: true }));
  }

  async _submit() {
    const form = this.querySelector('#bean-form');
    const fd = new FormData(form);

    const body = {
      roaster: fd.get('roaster') || '',
      name: fd.get('name') || '',
    };

    // Optional text fields
    const optionalText = ['species', 'country', 'region', 'producer', 'processing', 'decafProcess', 'notes'];
    for (const key of optionalText) {
      const v = fd.get(key);
      if (v) body[key] = v;
    }

    // Variety — comma-separated to array
    const varietyStr = fd.get('variety');
    if (varietyStr) {
      body.variety = varietyStr.split(',').map(s => s.trim()).filter(Boolean);
    }

    // Altitude — "min-max" to [min, max]
    const altStr = fd.get('altitude');
    if (altStr) {
      const parts = altStr.split('-').map(s => parseInt(s.trim(), 10)).filter(n => !isNaN(n));
      if (parts.length > 0) body.altitude = parts;
    }

    // Decaf
    body.decaf = !!form.querySelector('input[name="decaf"]').checked;

    // Remove decafProcess if not decaf
    if (!body.decaf) delete body.decafProcess;

    try {
      const url = this._beanId ? '/api/v1/beans/' + this._beanId : '/api/v1/beans';
      const method = this._beanId ? 'PUT' : 'POST';
      const res = await fetch(url, {
        method,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (!res.ok) {
        const text = await res.text();
        throw new Error('HTTP ' + res.status + ': ' + text);
      }
      this.dispatchEvent(new CustomEvent('bean-saved', { bubbles: true }));
    } catch (err) {
      this._error = 'Save failed: ' + err.message;
      this.render();
    }
  }
}
customElements.define('dye2-bean-form', Dye2BeanForm);
`;
