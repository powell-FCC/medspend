import { createFileRoute, Link } from "@tanstack/react-router";
import {
  BarChart3,
  Check,
  ClipboardCheck,
  FileText,
  LayoutDashboard,
  PackagePlus,
  Play,
  Search,
  ShoppingCart,
  Truck,
  Users,
} from "lucide-react";
import { SportSpendLogo } from "@/components/brand/SportSpendLogo";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "SportSpend — Supply requests and purchasing insights" },
      {
        name: "description",
        content:
          "SportSpend helps athletic training staff request supplies and gives sports operations leaders clear purchasing and vendor insights.",
      },
      { property: "og:title", content: "SportSpend" },
      {
        property: "og:description",
        content: "Supply requests and purchasing insights for athletic operations.",
      },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary_large_image" },
    ],
  }),
  component: Landing,
});

function Landing() {
  return (
    <div className="sportspend-public">
      <header className="sp-header">
        <a href="#top" className="sp-brand-link" aria-label="SportSpend home">
          <SportSpendLogo className="sp-header-logo" />
        </a>
        <nav className="sp-nav" aria-label="Main navigation">
          <a href="#product">Product</a>
          <a href="#solutions">Solutions</a>
          <span aria-disabled="true" title="Pricing information is coming soon">
            Pricing
          </span>
          <span aria-disabled="true" title="Resources are coming soon">
            Resources
          </span>
        </nav>
        <div className="sp-header-actions">
          <Link to="/auth" className="sp-sign-in">
            Sign in
          </Link>
          <Link to="/auth" className="sp-button sp-button-primary">
            Get started
          </Link>
        </div>
      </header>

      <main id="top">
        <section className="sp-hero" aria-labelledby="hero-title">
          <div className="sp-hero-copy">
            <p className="sp-eyebrow">
              <span />
              Supply requests. Purchasing insights.
            </p>
            <h1 id="hero-title">
              <span>Keep your team supplied.</span>
              <span>Make smarter decisions.</span>
            </h1>
            <p className="sp-hero-body">
              SportSpend gives athletic training staff a fast, simple way to request supplies, and
              gives owners and administrators powerful insights into purchasing, spending, and
              vendor pricing — all in one place.
            </p>
            <div className="sp-hero-actions">
              <Link to="/auth" className="sp-button sp-button-primary">
                Get started
              </Link>
              <button
                type="button"
                className="sp-button sp-button-secondary"
                disabled
                title="Product overview coming soon"
              >
                <span className="sp-play">
                  <Play aria-hidden="true" />
                </span>
                Watch overview
              </button>
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

        <section id="solutions" className="sp-features" aria-label="SportSpend capabilities">
          <Feature icon={<ShoppingCart />} title="Supply requests">
            Quick and easy for staff
          </Feature>
          <Feature icon={<ClipboardCheck />} title="Approval workflow">
            Keep purchasing organized and accountable
          </Feature>
          <Feature icon={<BarChart3 />} title="Purchasing insights">
            See what you&apos;re spending and where
          </Feature>
          <Feature icon={<Users />} title="Role-based access">
            Right people. Right permissions.
          </Feature>
        </section>

        <section id="product" className="sp-product" aria-labelledby="product-title">
          <ProductPreview />
          <div className="sp-product-copy">
            <p className="sp-eyebrow">
              <span />
              Built for athletic operations
            </p>
            <h2 id="product-title">A simpler way to manage supplies.</h2>
            <p>
              From request to reconciliation, SportSpend keeps everyone aligned and gives you the
              data to make smarter purchasing decisions.
            </p>
            <ul>
              {[
                "Mobile-friendly for staff",
                "Fast, transparent approvals",
                "Track spending and invoices",
                "Review vendor pricing history",
                "Built for sports medicine",
              ].map((item) => (
                <li key={item}>
                  <span>
                    <Check aria-hidden="true" />
                  </span>
                  {item}
                </li>
              ))}
            </ul>
          </div>
        </section>

        <section className="sp-cta" aria-label="Get started with SportSpend">
          <div className="sp-cta-inner">
            <div className="sp-cta-logo-wrap">
              <SportSpendLogo className="sp-cta-logo" />
            </div>
            <Link to="/auth" className="sp-button sp-button-primary">
              Get started
            </Link>
          </div>
        </section>
      </main>

      <footer id="footer" className="sp-footer">
        <SportSpendLogo className="sp-footer-logo" />
        <nav aria-label="Footer navigation">
          <a href="#product">Product</a>
          <a href="#solutions">Solutions</a>
          <span aria-disabled="true">Pricing</span>
          <span aria-disabled="true">Resources</span>
          <span aria-disabled="true">Privacy</span>
          <span aria-disabled="true">Terms</span>
        </nav>
        <p>© 2026 SportSpend. All rights reserved.</p>
      </footer>
    </div>
  );
}

function Feature({
  icon,
  title,
  children,
}: {
  icon: React.ReactNode;
  title: string;
  children: React.ReactNode;
}) {
  return (
    <article className="sp-feature">
      <div className="sp-feature-icon" aria-hidden="true">
        {icon}
      </div>
      <h2>{title}</h2>
      <p>{children}</p>
    </article>
  );
}

function ProductPreview() {
  return (
    <div className="sp-product-visual" aria-label="SportSpend request inbox on desktop and mobile">
      <div className="sp-desktop-frame">
        <div className="sp-desktop-camera" />
        <div className="sp-app-preview">
          <aside>
            <SportSpendLogo className="sp-preview-logo" />
            <PreviewNav icon={<LayoutDashboard />} label="Dashboard" />
            <PreviewNav icon={<ClipboardCheck />} label="Staff" active />
            <PreviewNav icon={<Truck />} label="Orders" />
            <PreviewNav icon={<FileText />} label="Invoices" />
          </aside>
          <div className="sp-preview-content">
            <div className="sp-preview-toolbar">
              <span>
                <Search aria-hidden="true" />
                Search requests
              </span>
              <button type="button" tabIndex={-1}>
                <PackagePlus aria-hidden="true" />
                New request
              </button>
            </div>
            <p className="sp-preview-kicker">Supply operations</p>
            <h3>Request Inbox</h3>
            <div className="sp-preview-metrics">
              <span>
                <b>3</b> Needs review
              </span>
              <span>
                <b>5</b> Awaiting order
              </span>
              <span>
                <b>2</b> Awaiting delivery
              </span>
            </div>
            <div className="sp-request-list">
              <PreviewRequest
                title="Athletic tape restock"
                person="Jordan Miller · Training room"
                status="Needs review"
              />
              <PreviewRequest
                title="Cold therapy wraps"
                person="Sam Carter · Football"
                status="Approved"
              />
              <PreviewRequest
                title="First aid supplies"
                person="Alex Nguyen · Field house"
                status="Ordered"
              />
            </div>
          </div>
        </div>
      </div>

      <div className="sp-phone-frame">
        <div className="sp-phone-speaker" />
        <div className="sp-phone-screen">
          <SportSpendLogo className="sp-phone-logo" />
          <p className="sp-phone-kicker">Staff workspace</p>
          <h3>Good afternoon</h3>
          <button type="button" tabIndex={-1}>
            <PackagePlus aria-hidden="true" />
            Request supplies
          </button>
          <div className="sp-phone-card">
            <span>Recent request</span>
            <strong>Athletic tape</strong>
            <small>Awaiting review</small>
          </div>
          <nav aria-label="Mobile preview navigation">
            <span>
              <LayoutDashboard />
              Home
            </span>
            <span className="active">
              <PackagePlus />
              Request
            </span>
            <span>
              <ClipboardCheck />
              Requests
            </span>
          </nav>
        </div>
      </div>
    </div>
  );
}

function PreviewNav({
  icon,
  label,
  active = false,
}: {
  icon: React.ReactNode;
  label: string;
  active?: boolean;
}) {
  return (
    <div className={active ? "active" : ""}>
      {icon}
      <span>{label}</span>
    </div>
  );
}

function PreviewRequest({
  title,
  person,
  status,
}: {
  title: string;
  person: string;
  status: string;
}) {
  return (
    <div className="sp-preview-request">
      <span>
        <strong>{title}</strong>
        <small>{person}</small>
      </span>
      <b data-status={status}>{status}</b>
    </div>
  );
}
