import { api } from "../shared/api";
import { $, tpl } from "../shared/dom";

type Hello = { message?: string } & Record<string, unknown>;

export async function home(): Promise<void> {
  const host = $<HTMLDivElement>("#hello");
  try {
    const data = await api<Hello>("/api/hello");
    const node = tpl("tpl-hello");
    $('[data-slot="message"]', node).textContent = data.message ?? "(no message field)";
    $('[data-slot="raw"]', node).textContent = JSON.stringify(data, null, 2);
    host.replaceChildren(node);
  } catch (err) {
    const node = tpl("tpl-error");
    const msg = err instanceof Error ? err.message : String(err);
    $('[data-slot="error"]', node).textContent = `Request failed: ${msg}`;
    host.replaceChildren(node);
  }
}
