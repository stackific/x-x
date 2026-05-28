export function notFound(): string {
  return `
    <section class="container padding">
      <h3>404</h3>
      <div class="space"></div>
      <p>The page you're looking for doesn't exist.</p>
      <div class="space"></div>
      <a href="/" class="button">Go home</a>
    </section>
  `;
}
