import clsx from 'clsx';
import { Link } from 'react-router-dom';
import { useI18n } from '../i18n';

export function LogoMark({ className }: { className?: string }) {
  return <img src="/brand/logo-mark.png" alt="" aria-hidden className={clsx('h-9 w-9 object-contain', className)} />;
}

export function Logo({ to = '/', tagline = true, inverse, className, size = 'md' }:
  { to?: string; tagline?: boolean; inverse?: boolean; className?: string; size?: 'sm' | 'md' | 'lg' }) {
  const { t } = useI18n();
  const text = { sm: 'text-xl', md: 'text-2xl', lg: 'text-3xl' }[size];
  const mark = { sm: 'h-8 w-8', md: 'h-10 w-10', lg: 'h-12 w-12' }[size];
  return (
    <Link to={to} className={clsx('inline-flex items-center gap-2', className)} aria-label="BizPilot">
      <LogoMark className={mark} />
      <span className="flex flex-col leading-none">
        <span className={clsx('font-extrabold tracking-tight', text)}>
          <span className={inverse ? 'text-white' : 'text-ink dark:text-white'}>Biz</span>
          <span className={inverse ? 'text-brand-300' : 'text-brand-600 dark:text-brand-400'}>Pilot</span>
        </span>
        {tagline && (
          <span className={clsx('mt-1 text-[8.5px] font-bold uppercase tracking-[0.22em]', inverse ? 'text-gray-300' : 'text-ink-soft dark:text-gray-400')}>
            {t('brand.tagline')}
          </span>
        )}
      </span>
    </Link>
  );
}
