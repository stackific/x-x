import { essayLayout } from "../layouts/essay";

export function essay(): string {
  const content = `
    <p>Sample essay body paragraph. Layout-only placeholder &mdash; replace with real content once data lands.</p>
    <p>Another paragraph so spacing between blocks can be reviewed in light and dark modes.</p>
    <h4>Subheading</h4>
    <p>Body text under a subheading to check rhythm.</p>
    <ul>
      <li>Bullet item one</li>
      <li>Bullet item two</li>
      <li>Bullet item three</li>
    </ul>
  `;
  return essayLayout(
    {
      title: "Sample essay title for layout review",
      category: "sample",
      categoryName: "Sample category",
      parentCategory: { id: "parent", name: "Parent category" },
      minibook: { id: "sample-minibook", name: "Sample minibook" },
      createdAt: "2026-01-01",
    },
    content,
  );
}
