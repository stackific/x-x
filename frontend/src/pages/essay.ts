import { $, tpl } from "../shared/dom";
import { qs as getQs } from "../shared/qs";

type Essay = {
  slug: string;
  title: string;
  system: { id: string; name: string };
  parentSystem?: { id: string; name: string };
  minibook?: { id: string; name: string };
  createdAt: string;
  thumbnail?: string;
  body: string;
};

const PLACEHOLDER: Essay = {
  slug: "sample",
  title: "Sample essay title for layout review",
  system: { id: "sample", name: "Sample system" },
  parentSystem: { id: "parent", name: "Parent system" },
  minibook: { id: "sample-minibook", name: "Sample minibook" },
  createdAt: "2026-01-01",
  body: `
    <p>Sample essay body paragraph. Layout-only placeholder &mdash; replace with real content once data lands.</p>
    <p>Another paragraph so spacing between blocks can be reviewed in light and dark modes.</p>
    <h4>Subheading</h4>
    <p>Body text under a subheading to check rhythm.</p>
    <ul>
      <li>Bullet item one</li>
      <li>Bullet item two</li>
      <li>Bullet item three</li>
    </ul>
  `,
};

function formatLongDate(iso: string): string {
  return new Date(iso).toLocaleDateString("en-US", {
    year: "numeric",
    month: "long",
    day: "numeric",
  });
}

function chip(templateId: string, name: string, href: string): DocumentFragment {
  const node = tpl(templateId);
  const a = node.querySelector<HTMLAnchorElement>("a");
  if (a) a.href = href;
  $('[data-slot="name"]', node).textContent = name;
  return node;
}

export function essay(): void {
  const slug = getQs("slug");
  // TODO: when /api/essays/:slug is ready:
  //   const data = await api<Essay>(`/api/essays/${encodeURIComponent(slug)}`);
  const data: Essay = slug ? { ...PLACEHOLDER, slug, title: `Essay: ${slug}` } : PLACEHOLDER;

  $<HTMLHeadingElement>("#essay-title").textContent = data.title;
  const cover = $<HTMLImageElement>("#essay-cover");
  cover.src = data.thumbnail || "/default-cover.jpg";
  cover.alt = data.title;

  const meta = $<HTMLDivElement>("#essay-meta");
  meta.replaceChildren();

  if (data.parentSystem) {
    meta.appendChild(
      chip(
        "tpl-chip-parent",
        data.parentSystem.name,
        `/system?id=${encodeURIComponent(data.parentSystem.id)}`,
      ),
    );
  }
  meta.appendChild(
    chip("tpl-chip-system", data.system.name, `/system?id=${encodeURIComponent(data.system.id)}`),
  );
  if (data.minibook) {
    meta.appendChild(
      chip(
        "tpl-chip-minibook",
        data.minibook.name,
        `/minibooks?id=${encodeURIComponent(data.minibook.id)}`,
      ),
    );
  }
  const dateNode = tpl("tpl-date");
  $('[data-slot="date"]', dateNode).textContent = formatLongDate(data.createdAt);
  meta.appendChild(dateNode);

  // Essay body HTML comes from a trusted backend; assigned via innerHTML so
  // it renders as markup instead of escaped text.
  $<HTMLDivElement>("#essay-content").innerHTML = data.body;
}
