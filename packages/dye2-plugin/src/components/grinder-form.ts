export const grinderFormComponent = `
class Dye2GrinderForm extends HTMLElement {
  constructor() {
    super();
    this._grinderId = null;
    this._loading = false;
    this._error = null;
    this._data = {};
  }

  static get observedAttributes() {
    return ['grinder-id'];
  }

  attributeChangedCallback(name, oldVal, newVal) {
    if (name === 'grinder-id') {
      this._grinderId = newVal;
    }
  }

  connectedCallback() {
    this._grinderId = this.getAttribute('grinder-id') || null;
    this._data = {};
    this._error = null;
    if (this._grinderId) {
      this._loadGrinder();
    } else {
      this.render();
    }
  }

  async _loadGrinder() {
    this._loading = true;
    this.render();
    try {
      const res = await fetch('/api/v1/grinders/' + this._grinderId);
      if (!res.ok) throw new Error('HTTP ' + res.status);
      this._data = await res.json();
      this._loading = false;
      this.render();
    } catch (err) {
      this._loading = false;
      this._error = 'Failed to load grinder: ' + err.message;
      this.render();
    }
  }

  _val(field) {
    return this._data[field] != null ? this._data[field] : '';
  }

  _numVal(field) {
    const v = this._data[field];
    return v != null ? v : '';
  }

  render() {
    if (this._loading) {
      this.innerHTML = '<div class="card"><p class="text-muted">Loading grinder...</p></div>';
      return;
    }
    if (this._error) {
      this.innerHTML = '<div class="card"><p style="color:#ff6b6b;">' + this._error + '</p>'
        + '<button data-action="cancel">Back</button></div>';
      this.querySelector('[data-action="cancel"]').addEventListener('click', () => this._cancel());
      return;
    }

    const isEdit = !!this._grinderId;
    const settingType = this._data.settingType || 'numeric';
    const isNumeric = settingType === 'numeric';
    const settingValues = Array.isArray(this._data.settingValues)
      ? this._data.settingValues.join(', ')
      : (this._data.settingValues || '');

    this.innerHTML = \`
      <div class="card">
        <h2>\${isEdit ? 'Edit Grinder' : 'New Grinder'}</h2>
        <form id="grinder-form">
          <div class="mb-8">
            <label class="text-small text-muted">Model *</label>
            <input name="model" required value="\${this._esc(this._val('model'))}" placeholder="Grinder model" />
          </div>
          <div class="grid grid-2 mb-8">
            <div>
              <label class="text-small text-muted">Burrs</label>
              <input name="burrs" value="\${this._esc(this._val('burrs'))}" placeholder="Burr set name" />
            </div>
            <div>
              <label class="text-small text-muted">Burr Type</label>
              <select name="burrType">
                <option value="">-- Select --</option>
                <option value="flat" \${this._val('burrType') === 'flat' ? 'selected' : ''}>Flat</option>
                <option value="conical" \${this._val('burrType') === 'conical' ? 'selected' : ''}>Conical</option>
              </select>
            </div>
          </div>
          <div class="grid grid-2 mb-8">
            <div>
              <label class="text-small text-muted">Burr Size (mm)</label>
              <input name="burrSize" type="number" step="any" value="\${this._numVal('burrSize')}" placeholder="e.g. 64" />
            </div>
            <div>
              <label class="text-small text-muted">Setting Type</label>
              <select name="settingType">
                <option value="numeric" \${isNumeric ? 'selected' : ''}>Numeric</option>
                <option value="preset" \${!isNumeric ? 'selected' : ''}>Preset</option>
              </select>
            </div>
          </div>
          <div id="numeric-settings" class="\${isNumeric ? '' : 'hidden'}">
            <div class="grid grid-2 mb-8">
              <div>
                <label class="text-small text-muted">Setting Small Step</label>
                <input name="settingSmallStep" type="number" step="any" value="\${this._numVal('settingSmallStep')}" placeholder="e.g. 0.1" />
              </div>
              <div>
                <label class="text-small text-muted">Setting Big Step</label>
                <input name="settingBigStep" type="number" step="any" value="\${this._numVal('settingBigStep')}" placeholder="e.g. 1" />
              </div>
            </div>
          </div>
          <div id="preset-settings" class="\${isNumeric ? 'hidden' : ''}">
            <div class="mb-8">
              <label class="text-small text-muted">Setting Values (comma-separated)</label>
              <input name="settingValues" value="\${this._esc(settingValues)}" placeholder="e.g. Fine, Medium, Coarse" />
            </div>
          </div>
          <div class="grid grid-2 mb-8">
            <div>
              <label class="text-small text-muted">RPM Small Step</label>
              <input name="rpmSmallStep" type="number" step="any" value="\${this._numVal('rpmSmallStep')}" placeholder="e.g. 10" />
            </div>
            <div>
              <label class="text-small text-muted">RPM Big Step</label>
              <input name="rpmBigStep" type="number" step="any" value="\${this._numVal('rpmBigStep')}" placeholder="e.g. 100" />
            </div>
          </div>
          <div class="mb-8">
            <label class="text-small text-muted">Notes</label>
            <textarea name="notes" rows="3" placeholder="Notes about this grinder...">\${this._esc(this._val('notes'))}</textarea>
          </div>
          <div class="flex">
            <button type="submit" class="primary">\${isEdit ? 'Save' : 'Create'}</button>
            <button type="button" data-action="cancel">Cancel</button>
          </div>
        </form>
      </div>
    \`;

    // Toggle setting type sections
    const settingTypeSelect = this.querySelector('select[name="settingType"]');
    const numericSection = this.querySelector('#numeric-settings');
    const presetSection = this.querySelector('#preset-settings');
    if (settingTypeSelect) {
      settingTypeSelect.addEventListener('change', () => {
        const isNum = settingTypeSelect.value === 'numeric';
        numericSection.classList.toggle('hidden', !isNum);
        presetSection.classList.toggle('hidden', isNum);
      });
    }

    // Cancel button
    this.querySelector('[data-action="cancel"]').addEventListener('click', () => this._cancel());

    // Form submit
    this.querySelector('#grinder-form').addEventListener('submit', (e) => {
      e.preventDefault();
      this._submit();
    });
  }

  _esc(val) {
    if (val == null) return '';
    return String(val).replace(/&/g,'&amp;').replace(/"/g,'&quot;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }

  _cancel() {
    this.dispatchEvent(new CustomEvent('grinder-cancelled', { bubbles: true }));
  }

  async _submit() {
    const form = this.querySelector('#grinder-form');
    const fd = new FormData(form);

    const body = {
      model: fd.get('model') || '',
    };

    // Optional text fields
    const optText = ['burrs', 'burrType', 'notes'];
    for (const key of optText) {
      const v = fd.get(key);
      if (v) body[key] = v;
    }

    // Numeric fields
    const optNum = ['burrSize', 'rpmSmallStep', 'rpmBigStep'];
    for (const key of optNum) {
      const v = fd.get(key);
      if (v !== '' && v != null) body[key] = parseFloat(v);
    }

    // Setting type
    const st = fd.get('settingType') || 'numeric';
    body.settingType = st;

    if (st === 'numeric') {
      const ss = fd.get('settingSmallStep');
      const bs = fd.get('settingBigStep');
      if (ss !== '' && ss != null) body.settingSmallStep = parseFloat(ss);
      if (bs !== '' && bs != null) body.settingBigStep = parseFloat(bs);
    } else {
      // Preset — comma-separated to array
      const svStr = fd.get('settingValues');
      if (svStr) {
        body.settingValues = svStr.split(',').map(s => s.trim()).filter(Boolean);
      }
    }

    try {
      const url = this._grinderId ? '/api/v1/grinders/' + this._grinderId : '/api/v1/grinders';
      const method = this._grinderId ? 'PUT' : 'POST';
      const res = await fetch(url, {
        method,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      if (!res.ok) {
        const text = await res.text();
        throw new Error('HTTP ' + res.status + ': ' + text);
      }
      this.dispatchEvent(new CustomEvent('grinder-saved', { bubbles: true }));
    } catch (err) {
      this._error = 'Save failed: ' + err.message;
      this.render();
    }
  }
}
customElements.define('dye2-grinder-form', Dye2GrinderForm);
`;
