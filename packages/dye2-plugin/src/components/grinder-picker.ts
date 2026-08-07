export const grinderPickerComponent = `
class Dye2GrinderPicker extends HTMLElement {
  constructor() {
    super();
    this._grinders = [];
    this._selectedGrinderId = null;
    this._loading = true;
  }

  connectedCallback() {
    this.render();
    this.fetchGrinders();
  }

  async fetchGrinders() {
    this._loading = true;
    this.render();
    try {
      const res = await fetch('/api/v1/grinders');
      if (!res.ok) throw new Error('HTTP ' + res.status);
      this._grinders = await res.json();
      this._loading = false;
      this.render();
    } catch (err) {
      this._loading = false;
      this.innerHTML = '<p style="color: #ff6b6b;">Failed to load grinders: ' + err.message + '</p>';
    }
  }

  async selectGrinder(grinder) {
    this._selectedGrinderId = grinder.id;
    this.render();

    const detail = {
      grinderId: grinder.id,
      grinderModel: grinder.model || '',
    };

    // Update workflow
    try {
      await fetch('/api/v1/workflow', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ context: detail }),
      });
    } catch (err) {
      console.error('[dye2-grinder-picker] Workflow update failed:', err);
    }

    // Dispatch DOM event
    this.dispatchEvent(new CustomEvent('picker-done', { detail, bubbles: true }));

    // PostMessage for iframe integration
    window.parent.postMessage({ type: 'dye2-picker-done', ...detail }, '*');
  }

  _esc(val) {
    if (val == null) return '';
    return String(val).replace(/&/g,'&amp;').replace(/"/g,'&quot;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }

  render() {
    if (this._loading) {
      this.innerHTML = '<h1>Select Grinder</h1><div class="card"><p class="text-muted">Loading grinders...</p></div>';
      return;
    }

    const grinders = this._grinders;
    this.innerHTML = \`
      <h1>Select Grinder</h1>
      \${grinders.length === 0
        ? '<p class="text-muted">No grinders available. Add grinders in the Grinders management page.</p>'
        : grinders.map(g => {
            const isSelected = this._selectedGrinderId === g.id;
            const selectedStyle = isSelected
              ? 'border-color: #2ecc71; background: #1a3a2a;'
              : '';
            return \`
              <div class="card picker-grinder" data-grinder-id="\${g.id}"
                   style="cursor:pointer;\${selectedStyle}">
                <div class="flex-between">
                  <div class="flex">
                    \${isSelected ? '<span style="color:#2ecc71;margin-right:6px;">&#10003;</span>' : ''}
                    <strong>\${this._esc(g.model) || 'Unnamed'}</strong>
                  </div>
                  <div class="flex">
                    \${g.settingType ? '<span class="tag">' + this._esc(g.settingType) + '</span>' : ''}
                  </div>
                </div>
                <div class="flex text-small text-muted mt-8">
                  \${g.burrs ? '<span>Burrs: ' + this._esc(g.burrs) + '</span>' : ''}
                  \${g.burrType ? '<span>Type: ' + this._esc(g.burrType) + '</span>' : ''}
                  \${g.burrSize ? '<span>Size: ' + g.burrSize + 'mm</span>' : ''}
                </div>
                \${g.notes ? '<div class="text-small text-muted mt-8" style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">' + this._esc(g.notes) + '</div>' : ''}
              </div>
            \`;
          }).join('')
      }
    \`;

    // Event listeners
    this.querySelectorAll('.picker-grinder[data-grinder-id]').forEach(card => {
      card.addEventListener('click', () => {
        const id = card.getAttribute('data-grinder-id');
        const grinder = this._grinders.find(g => g.id === id) || { id };
        this.selectGrinder(grinder);
      });
    });
  }
}
customElements.define('dye2-grinder-picker', Dye2GrinderPicker);
`;
