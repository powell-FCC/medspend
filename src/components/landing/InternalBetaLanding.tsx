import { Link } from "@tanstack/react-router";
import { SportSpendLogo } from "@/components/brand/SportSpendLogo";
import "./internal-beta.css";

export const internalBetaLandingHead = () => ({
  meta: [
    { title: "SportSpend — Internal Beta" },
    {
      name: "description",
      content: "A simpler way for FC Cincinnati staff to request supplies and manage purchasing workflows.",
    },
    { property: "og:title", content: "SportSpend" },
    { property: "og:description", content: "Built for sport. Driven by data." },
    { property: "og:type", content: "website" },
    { name: "twitter:card", content: "summary_large_image" },
  ],
});

export function InternalBetaLanding() {
  return (
    <div className="sportspend-public sp-internal-beta">
      <header className="sp-header">
        <a href="#top" className="sp-brand-link" aria-label="SportSpend home">
          <SportSpendLogo className="sp-header-logo" />
        </a>
        <Link to="/auth" className="sp-sign-in">
          Sign in
        </Link>
      </header>

      <main id="top">
        <section className="sp-hero" aria-labelledby="hero-title">
          <div className="sp-hero-copy">
            <p className="sp-eyebrow">
              <span aria-hidden="true" />
              Internal Beta
            </p>
            <h1 id="hero-title">Keep your team supplied.</h1>
            <p className="sp-hero-body">
              A simpler way for FC Cincinnati staff to request supplies and manage purchasing
              workflows.
            </p>
            <div className="sp-hero-actions">
              <Link to="/auth" className="sp-button sp-button-primary">
                Sign in
              </Link>
            </div>
          </div>
          <figure className="sp-hero-visual" aria-label="A professional sports stadium at sunset">
            <div className="sp-hero-accent" aria-hidden="true" />
            <img
              src="/brand/sportspend-stadium-hero.png"
              alt="Empty professional sports stadium at sunset"
              width={1536}
              height={1024}
            />
          </figure>
        </section>
      </main>

      <footer className="sp-footer">
        <p>Built for sport. Driven by data.</p>
        <p>© 2026 SportSpend. All rights reserved.</p>
      </footer>
    </div>
  );
}
