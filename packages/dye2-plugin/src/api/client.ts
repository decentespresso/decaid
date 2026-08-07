
const API_BASE = "/api/v1";

export const api = {
  async listBeans(includeArchived = false): Promise<unknown[]> {
    const params = includeArchived ? "?archived=true" : "";
    const res = await fetch(`${API_BASE}/beans${params}`);
    return res.json();
  },

  async getBean(id: string): Promise<unknown> {
    const res = await fetch(`${API_BASE}/beans/${id}`);
    return res.json();
  },

  async createBean(bean: Record<string, unknown>): Promise<unknown> {
    const res = await fetch(`${API_BASE}/beans`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(bean),
    });
    return res.json();
  },

  async updateBean(
    id: string,
    bean: Record<string, unknown>
  ): Promise<unknown> {
    const res = await fetch(`${API_BASE}/beans/${id}`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(bean),
    });
    return res.json();
  },

  async deleteBean(id: string): Promise<void> {
    await fetch(`${API_BASE}/beans/${id}`, { method: "DELETE" });
  },

  async listBatches(beanId: string): Promise<unknown[]> {
    const res = await fetch(`${API_BASE}/beans/${beanId}/batches`);
    return res.json();
  },

  async createBatch(
    beanId: string,
    batch: Record<string, unknown>
  ): Promise<unknown> {
    const res = await fetch(`${API_BASE}/beans/${beanId}/batches`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(batch),
    });
    return res.json();
  },

  async updateBatch(
    id: string,
    batch: Record<string, unknown>
  ): Promise<unknown> {
    const res = await fetch(`${API_BASE}/bean-batches/${id}`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(batch),
    });
    return res.json();
  },

  async deleteBatch(id: string): Promise<void> {
    await fetch(`${API_BASE}/bean-batches/${id}`, { method: "DELETE" });
  },

  async listGrinders(includeArchived = false): Promise<unknown[]> {
    const params = includeArchived ? "?archived=true" : "";
    const res = await fetch(`${API_BASE}/grinders${params}`);
    return res.json();
  },

  async getGrinder(id: string): Promise<unknown> {
    const res = await fetch(`${API_BASE}/grinders/${id}`);
    return res.json();
  },

  async createGrinder(grinder: Record<string, unknown>): Promise<unknown> {
    const res = await fetch(`${API_BASE}/grinders`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(grinder),
    });
    return res.json();
  },

  async updateGrinder(
    id: string,
    grinder: Record<string, unknown>
  ): Promise<unknown> {
    const res = await fetch(`${API_BASE}/grinders/${id}`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(grinder),
    });
    return res.json();
  },

  async deleteGrinder(id: string): Promise<void> {
    await fetch(`${API_BASE}/grinders/${id}`, { method: "DELETE" });
  },

  async getWorkflow(): Promise<unknown> {
    const res = await fetch(`${API_BASE}/workflow`);
    return res.json();
  },

  async updateWorkflow(
    workflow: Record<string, unknown>
  ): Promise<unknown> {
    const res = await fetch(`${API_BASE}/workflow`, {
      method: "PUT",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(workflow),
    });
    return res.json();
  },
};
