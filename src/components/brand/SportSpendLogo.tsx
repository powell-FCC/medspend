type SportSpendLogoProps = {
  className?: string;
};

export function SportSpendLogo({ className = "" }: SportSpendLogoProps) {
  return (
    <img
      src="/brand/sportspend-logo-horizontal.png"
      width={2172}
      height={724}
      alt="SportSpend — Built for sport. Driven by data."
      className={className}
      draggable={false}
    />
  );
}
