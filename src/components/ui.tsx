import { ButtonHTMLAttributes, Children, cloneElement, forwardRef, InputHTMLAttributes, isValidElement, ReactElement, ReactNode, SelectHTMLAttributes,
  TextareaHTMLAttributes, useEffect, useId, useRef, useState } from 'react';
import clsx from 'clsx';
import { AlertTriangle, ArrowDownRight, ArrowUpRight, Eye, EyeOff, Inbox, Loader2, Lock, X } from 'lucide-react';
import { Link } from 'react-router-dom';
import { useI18n } from '../i18n';
import { errorMessage } from '../lib/errors';
import { formatMoney, formatPct } from '../lib/format';

// ---------------------------------------------------------------------------
// Buttons
// ---------------------------------------------------------------------------
type Variant = 'primary' | 'secondary' | 'outline' | 'ghost' | 'danger' | 'subtle';
type Size = 'sm' | 'md' | 'lg';

const variants: Record<Variant, string> = {
  primary: 'bg-brand-700 text-white hover:bg-brand-800 focus-visible:ring-brand-500 shadow-xs',
  secondary: 'bg-brand-50 text-brand-800 hover:bg-brand-100 dark:bg-brand-900/40 dark:text-brand-100 dark:hover:bg-brand-900/70',
  outline: 'border border-gray-300 bg-white text-ink hover:bg-gray-50 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100 dark:hover:bg-gray-800',
  ghost: 'text-ink-soft hover:bg-gray-100 dark:text-gray-300 dark:hover:bg-gray-800',
  danger: 'bg-red-600 text-white hover:bg-red-700 focus-visible:ring-red-500',
  subtle: 'bg-gray-100 text-ink hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-100 dark:hover:bg-gray-700',
};
const sizes: Record<Size, string> = {
  sm: 'h-8 px-3 text-sm gap-1.5', md: 'h-10 px-4 text-sm gap-2', lg: 'h-12 px-5 text-base gap-2',
};

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: Variant; size?: Size; loading?: boolean; icon?: ReactNode; block?: boolean;
}

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  { variant = 'primary', size = 'md', loading, icon, block, className, children, disabled, type = 'button', ...rest }, ref) {
  return (
    <button ref={ref} type={type} disabled={disabled || loading}
      className={clsx('inline-flex select-none items-center justify-center whitespace-nowrap rounded-lg font-semibold transition focus:outline-hidden focus-visible:ring-2 focus-visible:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-60 dark:focus-visible:ring-offset-gray-950',
        variants[variant], sizes[size], block && 'w-full', className)} {...rest}>
      {loading ? <Loader2 className="h-4 w-4 animate-spin" /> : icon}
      {children}
    </button>
  );
});

export function LinkButton({ to, variant = 'primary', size = 'md', icon, className, children, block }:
  { to: string; variant?: Variant; size?: Size; icon?: ReactNode; className?: string; children: ReactNode; block?: boolean }) {
  return (
    <Link to={to} className={clsx('inline-flex items-center justify-center rounded-lg font-semibold transition focus:outline-hidden focus-visible:ring-2 focus-visible:ring-brand-500',
      variants[variant], sizes[size], block && 'w-full', className)}>
      {icon}{children}
    </Link>
  );
}

// ---------------------------------------------------------------------------
// Form fields
// ---------------------------------------------------------------------------
const inputBase = 'block w-full rounded-lg border border-gray-300 bg-white px-3 text-sm text-ink placeholder:text-gray-400 shadow-xs transition focus:border-brand-600 focus:outline-hidden focus:ring-2 focus:ring-brand-600/20 disabled:bg-gray-50 disabled:text-gray-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100 dark:placeholder:text-gray-500 dark:disabled:bg-gray-800';

export function Field({ label, hint, error, children, required, optional, className, htmlFor }:
  { label?: ReactNode; hint?: ReactNode; error?: ReactNode; children: ReactNode; required?: boolean; optional?: boolean; className?: string; htmlFor?: string }) {
  const { t } = useI18n();
  // Associate the label with its control automatically (accessibility) when the
  // child is one of our form controls and no explicit id was given.
  const autoId = useId();
  let forId = htmlFor;
  let done = Boolean(htmlFor);
  const control = Children.map(children, (child) => {
    if (done || !isValidElement(child) || !FORM_CONTROLS.includes(child.type as never)) return child;
    done = true;
    const el = child as ReactElement<{ id?: string }>;
    forId = el.props.id ?? autoId;
    return cloneElement(el, { id: forId });
  });
  return (
    <div className={clsx('space-y-1.5', className)}>
      {label && (
        <label htmlFor={forId} className="block text-sm font-medium text-ink-soft dark:text-gray-300">
          {label}{required && <span className="text-red-600" aria-hidden="true"> *</span>}
          {optional && !required && <span className="ml-1.5 text-xs font-normal text-ink-muted dark:text-gray-400">({t('catalog.optional')})</span>}
        </label>
      )}
      {control}
      {error ? <p className="text-xs text-red-600">{error}</p> : hint ? <p className="text-xs text-ink-muted dark:text-gray-400">{hint}</p> : null}
    </div>
  );
}

export const Input = forwardRef<HTMLInputElement, InputHTMLAttributes<HTMLInputElement> & { suffix?: ReactNode; prefixIcon?: ReactNode }>(
  function Input({ className, suffix, prefixIcon, ...rest }, ref) {
    if (!suffix && !prefixIcon) return <input ref={ref} className={clsx(inputBase, 'h-10', className)} {...rest} />;
    return (
      <div className="relative">
        {prefixIcon && <span className="pointer-events-none absolute inset-y-0 left-3 flex items-center text-gray-400">{prefixIcon}</span>}
        <input ref={ref} className={clsx(inputBase, 'h-10', prefixIcon && 'pl-9', suffix && 'pr-16', className)} {...rest} />
        {suffix && <span className="pointer-events-none absolute inset-y-0 right-3 flex items-center text-xs font-medium text-gray-500">{suffix}</span>}
      </div>
    );
  });

// Password field with a show/hide toggle.
export const PasswordInput = forwardRef<HTMLInputElement, Omit<InputHTMLAttributes<HTMLInputElement>, 'type'>>(
  function PasswordInput({ className, ...rest }, ref) {
    const { t } = useI18n();
    const [visible, setVisible] = useState(false);
    return (
      <div className="relative">
        <input ref={ref} type={visible ? 'text' : 'password'} className={clsx(inputBase, 'h-10 pr-11', className)} {...rest} />
        <button type="button" onClick={() => setVisible((v) => !v)} aria-pressed={visible}
          aria-label={visible ? t('auth.hidePassword') : t('auth.showPassword')} title={visible ? t('auth.hidePassword') : t('auth.showPassword')}
          className="absolute inset-y-0 right-0 flex w-11 items-center justify-center rounded-r-lg text-gray-500 hover:text-ink focus:outline-hidden focus-visible:ring-2 focus-visible:ring-brand-600 dark:text-gray-400 dark:hover:text-white">
          {visible ? <EyeOff className="h-5 w-5" /> : <Eye className="h-5 w-5" />}
        </button>
      </div>
    );
  });

export const Textarea = forwardRef<HTMLTextAreaElement, TextareaHTMLAttributes<HTMLTextAreaElement>>(function Textarea({ className, ...rest }, ref) {
  return <textarea ref={ref} className={clsx(inputBase, 'min-h-[80px] py-2', className)} {...rest} />;
});

export const Select = forwardRef<HTMLSelectElement, SelectHTMLAttributes<HTMLSelectElement>>(function Select({ className, children, ...rest }, ref) {
  return <select ref={ref} className={clsx(inputBase, 'h-10 pr-8', className)} {...rest}>{children}</select>;
});

const FORM_CONTROLS: unknown[] = [];

export function Checkbox({ label, checked, onChange, hint, disabled }:
  { label: ReactNode; checked: boolean; onChange: (v: boolean) => void; hint?: ReactNode; disabled?: boolean }) {
  const id = useId();
  return (
    <div className="flex items-start gap-3">
      <input id={id} type="checkbox" checked={checked} disabled={disabled} onChange={(e) => onChange(e.target.checked)}
        className="mt-0.5 h-4 w-4 rounded border-gray-300 text-brand-700 focus:ring-brand-600" />
      <label htmlFor={id} className="text-sm">
        <span className="font-medium text-ink dark:text-gray-100">{label}</span>
        {hint && <span className="block text-xs text-ink-muted dark:text-gray-400">{hint}</span>}
      </label>
    </div>
  );
}

FORM_CONTROLS.push(Input, PasswordInput, Textarea, Select);

// ---------------------------------------------------------------------------
// Layout primitives
// ---------------------------------------------------------------------------
export function Card({ children, className, padded = true }: { children: ReactNode; className?: string; padded?: boolean }) {
  return (
    <section className={clsx('rounded-2xl border border-gray-200/80 bg-white shadow-card dark:border-gray-800 dark:bg-gray-900', padded && 'p-4 sm:p-5', className)}>
      {children}
    </section>
  );
}

export function CardHeader({ title, subtitle, action, className }: { title: ReactNode; subtitle?: ReactNode; action?: ReactNode; className?: string }) {
  return (
    <div className={clsx('mb-4 flex items-start justify-between gap-3', className)}>
      <div className="min-w-0">
        <h2 className="text-base font-bold text-ink dark:text-white">{title}</h2>
        {subtitle && <p className="mt-0.5 text-xs text-ink-muted dark:text-gray-400">{subtitle}</p>}
      </div>
      {action && <div className="shrink-0">{action}</div>}
    </div>
  );
}

export function PageHeader({ title, subtitle, actions, back }: { title: ReactNode; subtitle?: ReactNode; actions?: ReactNode; back?: ReactNode }) {
  return (
    <div className="mb-5 flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
      <div className="min-w-0">
        {back}
        <h1 className="text-2xl font-extrabold tracking-tight text-ink dark:text-white sm:text-[28px]">{title}</h1>
        {subtitle && <p className="mt-1 text-sm text-ink-muted dark:text-gray-400">{subtitle}</p>}
      </div>
      {actions && <div className="flex flex-wrap items-center gap-2">{actions}</div>}
    </div>
  );
}

const tones = {
  green: 'bg-brand-50 text-brand-800 ring-brand-600/20 dark:bg-brand-900/40 dark:text-brand-200',
  amber: 'bg-amber-50 text-amber-800 ring-amber-600/20 dark:bg-amber-900/30 dark:text-amber-200',
  red: 'bg-red-50 text-red-700 ring-red-600/20 dark:bg-red-900/30 dark:text-red-200',
  gray: 'bg-gray-100 text-gray-700 ring-gray-500/20 dark:bg-gray-800 dark:text-gray-300',
  blue: 'bg-blue-50 text-blue-700 ring-blue-600/20 dark:bg-blue-900/30 dark:text-blue-200',
  purple: 'bg-violet-50 text-violet-700 ring-violet-600/20 dark:bg-violet-900/30 dark:text-violet-200',
};
export type Tone = keyof typeof tones;

export function Badge({ tone = 'gray', children, className }: { tone?: Tone; children: ReactNode; className?: string }) {
  return <span className={clsx('inline-flex items-center gap-1 whitespace-nowrap rounded-full px-2 py-0.5 text-xs font-semibold ring-1 ring-inset', tones[tone], className)}>{children}</span>;
}

export function IconBubble({ tone = 'green', children, className }: { tone?: Tone; children: ReactNode; className?: string }) {
  const bg = { green: 'bg-brand-50 text-brand-700 dark:bg-brand-900/50 dark:text-brand-300', amber: 'bg-amber-50 text-amber-600 dark:bg-amber-900/40 dark:text-amber-300',
    red: 'bg-red-50 text-red-600 dark:bg-red-900/40 dark:text-red-300', gray: 'bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-300',
    blue: 'bg-blue-50 text-blue-600 dark:bg-blue-900/40 dark:text-blue-300', purple: 'bg-violet-50 text-violet-600 dark:bg-violet-900/40 dark:text-violet-300' }[tone];
  return <div className={clsx('flex h-11 w-11 shrink-0 items-center justify-center rounded-xl', bg, className)}>{children}</div>;
}

export function Spinner({ className }: { className?: string }) {
  return <Loader2 className={clsx('h-5 w-5 animate-spin text-brand-700', className)} aria-hidden />;
}

export function PageLoader() {
  const { t } = useI18n();
  return <div className="flex min-h-[40vh] items-center justify-center gap-3 text-sm text-ink-muted"><Spinner /> {t('common.loading')}</div>;
}

export function ErrorState({ error, onRetry, compact }: { error: unknown; onRetry?: () => void; compact?: boolean }) {
  const { t, has } = useI18n();
  return (
    <div role="alert" className={clsx('flex flex-col items-center justify-center gap-3 text-center', compact ? 'py-6' : 'py-16')}>
      <AlertTriangle className="h-8 w-8 text-amber-500" />
      <p className="max-w-md text-sm text-ink-soft dark:text-gray-300">{errorMessage(error, t, has)}</p>
      {onRetry && <Button variant="outline" size="sm" onClick={onRetry}>{t('common.retry')}</Button>}
    </div>
  );
}

export function EmptyState({ icon, title, body, action, className }: { icon?: ReactNode; title: ReactNode; body?: ReactNode; action?: ReactNode; className?: string }) {
  return (
    <div className={clsx('flex flex-col items-center justify-center px-4 py-12 text-center', className)}>
      <div className="mb-3 flex h-12 w-12 items-center justify-center rounded-2xl bg-brand-50 text-brand-700 dark:bg-brand-900/40 dark:text-brand-300">
        {icon ?? <Inbox className="h-6 w-6" />}
      </div>
      <h3 className="text-base font-bold text-ink dark:text-white">{title}</h3>
      {body && <p className="mt-1 max-w-md text-sm text-ink-muted dark:text-gray-400">{body}</p>}
      {action && <div className="mt-4">{action}</div>}
    </div>
  );
}

export function Alert({ tone = 'amber', title, children, action }: { tone?: 'amber' | 'red' | 'green' | 'blue'; title?: ReactNode; children?: ReactNode; action?: ReactNode }) {
  const c = { amber: 'border-amber-200 bg-amber-50 text-amber-900 dark:border-amber-900 dark:bg-amber-950/50 dark:text-amber-100',
    red: 'border-red-200 bg-red-50 text-red-900 dark:border-red-900 dark:bg-red-950/50 dark:text-red-100',
    green: 'border-brand-200 bg-brand-50 text-brand-900 dark:border-brand-900 dark:bg-brand-950/60 dark:text-brand-100',
    blue: 'border-blue-200 bg-blue-50 text-blue-900 dark:border-blue-900 dark:bg-blue-950/50 dark:text-blue-100' }[tone];
  return (
    <div className={clsx('flex flex-col gap-2 rounded-xl border px-4 py-3 text-sm sm:flex-row sm:items-center', c)} role={tone === 'red' ? 'alert' : 'note'}>
      <div className="flex-1">
        {title && <p className="font-semibold">{title}</p>}
        {children && <div className={clsx(title && 'mt-0.5', 'opacity-90')}>{children}</div>}
      </div>
      {action}
    </div>
  );
}

// ---------------------------------------------------------------------------
// Money & numbers
// ---------------------------------------------------------------------------
export function useMoney() {
  const { lang } = useI18n();
  return (v: number | string | null | undefined, currency = 'XAF') => formatMoney(v, lang, currency);
}

export function Delta({ value, inverse, suffix }: { value: number | null | undefined; inverse?: boolean; suffix?: ReactNode }) {
  const { lang, t } = useI18n();
  if (value === null || value === undefined || !Number.isFinite(value)) {
    return <span className="text-xs text-ink-muted dark:text-gray-400">{suffix ?? t('common.vsPrevious')}: —</span>;
  }
  const good = inverse ? value <= 0 : value >= 0;
  return (
    <span className="inline-flex flex-wrap items-center gap-1 text-xs">
      <span className={clsx('inline-flex items-center font-semibold', good ? 'text-brand-600 dark:text-brand-400' : 'text-red-600 dark:text-red-400')}>
        {value >= 0 ? <ArrowUpRight className="h-3.5 w-3.5" /> : <ArrowDownRight className="h-3.5 w-3.5" />}
        {value > 0 ? '+' : ''}{formatPct(value, lang, 0)}
      </span>
      <span className="text-ink-muted dark:text-gray-400">{suffix ?? t('common.vsPrevious')}</span>
    </span>
  );
}

// Shows "12,000 FCFA" as a large amount with a smaller currency so narrow cards don't cut the figure.
function splitCurrency(value: ReactNode): ReactNode {
  if (typeof value !== 'string') return value;
  const m = value.match(/^(.+?)[\s\u00a0\u202f]*(FCFA|XAF)$/);
  if (!m) return value;
  return <><span className="whitespace-nowrap tabular-nums">{m[1]}</span> <span className="whitespace-nowrap text-sm font-bold text-ink-muted dark:text-gray-400">{m[2]}</span></>;
}

export function StatCard({ label, value, icon, tone = 'green', delta, inverse, hint, to, deltaSuffix }:
  { label: ReactNode; value: ReactNode; icon?: ReactNode; tone?: Tone; delta?: number | null; inverse?: boolean; hint?: ReactNode; to?: string; deltaSuffix?: ReactNode }) {
  const body = (
    <Card className={clsx('h-full', to && 'transition hover:border-brand-300 hover:shadow-md')}>
      <div className="flex items-start gap-3">
        {icon && <IconBubble tone={tone}>{icon}</IconBubble>}
        <div className="min-w-0 flex-1">
          <p className="truncate text-sm font-medium text-ink-muted dark:text-gray-400">{label}</p>
          <p className="mt-1 text-xl font-extrabold tracking-tight text-ink dark:text-white 2xl:text-2xl">{splitCurrency(value)}</p>
          <div className="mt-1">{delta !== undefined ? <Delta value={delta} inverse={inverse} suffix={deltaSuffix} /> : hint && <span className="text-xs text-ink-muted dark:text-gray-400">{hint}</span>}</div>
        </div>
      </div>
    </Card>
  );
  return to ? <Link to={to} className="block">{body}</Link> : body;
}

// ---------------------------------------------------------------------------
// Overlay
// ---------------------------------------------------------------------------
export function Modal({ open, onClose, title, children, footer, size = 'md' }:
  { open: boolean; onClose: () => void; title: ReactNode; children: ReactNode; footer?: ReactNode; size?: 'sm' | 'md' | 'lg' | 'xl' }) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => e.key === 'Escape' && onClose();
    document.addEventListener('keydown', onKey);
    const prev = document.body.style.overflow;
    document.body.style.overflow = 'hidden';
    setTimeout(() => ref.current?.querySelector<HTMLElement>('input,select,textarea,button:not([data-close])')?.focus(), 30);
    return () => { document.removeEventListener('keydown', onKey); document.body.style.overflow = prev; };
  }, [open, onClose]);
  if (!open) return null;
  const w = { sm: 'sm:max-w-md', md: 'sm:max-w-lg', lg: 'sm:max-w-2xl', xl: 'sm:max-w-4xl' }[size];
  return (
    <div className="fixed inset-0 z-[90] flex items-end justify-center sm:items-center sm:p-4" role="dialog" aria-modal="true">
      <div className="absolute inset-0 bg-gray-950/50 backdrop-blur-[1px]" onClick={onClose} />
      <div ref={ref} className={clsx('relative flex max-h-[92vh] w-full flex-col rounded-t-2xl bg-white shadow-2xl dark:bg-gray-900 sm:rounded-2xl', w)}>
        <div className="flex items-center justify-between border-b border-gray-100 px-5 py-4 dark:border-gray-800">
          <h2 className="text-lg font-bold text-ink dark:text-white">{title}</h2>
          <button data-close onClick={onClose} className="rounded-lg p-1.5 text-gray-500 hover:bg-gray-100 dark:hover:bg-gray-800" aria-label="Close"><X className="h-5 w-5" /></button>
        </div>
        <div className="flex-1 overflow-y-auto px-5 py-4">{children}</div>
        {footer && <div className="flex flex-wrap justify-end gap-2 border-t border-gray-100 px-5 py-3 dark:border-gray-800">{footer}</div>}
      </div>
    </div>
  );
}

export function ConfirmDialog({ open, onClose, onConfirm, title, body, confirmLabel, danger, loading, children }:
  { open: boolean; onClose: () => void; onConfirm: () => void; title: ReactNode; body?: ReactNode; confirmLabel?: ReactNode;
    danger?: boolean; loading?: boolean; children?: ReactNode }) {
  const { t } = useI18n();
  return (
    <Modal open={open} onClose={onClose} title={title} size="sm"
      footer={<><Button variant="outline" onClick={onClose}>{t('common.cancel')}</Button>
        <Button variant={danger ? 'danger' : 'primary'} loading={loading} onClick={onConfirm}>{confirmLabel ?? t('common.confirm')}</Button></>}>
      {body && <p className="text-sm text-ink-soft dark:text-gray-300">{body}</p>}
      {children}
    </Modal>
  );
}

// ---------------------------------------------------------------------------
// Tabs, tables, misc
// ---------------------------------------------------------------------------
export function Tabs<T extends string>({ items, value, onChange, className }:
  { items: { value: T; label: ReactNode; hidden?: boolean }[]; value: T; onChange: (v: T) => void; className?: string }) {
  return (
    <div className={clsx('-mx-1 flex gap-1 overflow-x-auto px-1 pb-1', className)} role="tablist">
      {items.filter((i) => !i.hidden).map((i) => (
        <button key={i.value} role="tab" aria-selected={value === i.value} onClick={() => onChange(i.value)}
          className={clsx('whitespace-nowrap rounded-lg px-3.5 py-2 text-sm font-semibold transition',
            value === i.value ? 'bg-brand-700 text-white shadow-xs' : 'bg-white text-ink-soft ring-1 ring-gray-200 hover:bg-gray-50 dark:bg-gray-900 dark:text-gray-300 dark:ring-gray-800 dark:hover:bg-gray-800')}>
          {i.label}
        </button>
      ))}
    </div>
  );
}

export interface Column<T> {
  key: string; header: ReactNode; render?: (row: T) => ReactNode; className?: string; align?: 'left' | 'right' | 'center';
  hideOnMobile?: boolean;
}

export function DataTable<T>({ columns, rows, rowKey, onRowClick, empty, footer, dense }:
  { columns: Column<T>[]; rows: T[]; rowKey: (r: T) => string; onRowClick?: (r: T) => void; empty?: ReactNode; footer?: ReactNode; dense?: boolean }) {
  if (!rows.length && empty) return <>{empty}</>;
  return (
    <div className="-mx-4 overflow-x-auto sm:mx-0">
      <table className="min-w-full divide-y divide-gray-100 text-sm dark:divide-gray-800">
        <thead>
          <tr>
            {columns.map((c) => (
              <th key={c.key} scope="col" className={clsx('whitespace-nowrap px-4 py-2.5 text-xs font-semibold uppercase tracking-wide text-ink-muted dark:text-gray-400 sm:px-3',
                c.align === 'right' ? 'text-right' : c.align === 'center' ? 'text-center' : 'text-left', c.hideOnMobile && 'hidden md:table-cell', c.className)}>{c.header}</th>
            ))}
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {rows.map((r) => (
            <tr key={rowKey(r)} onClick={onRowClick ? () => onRowClick(r) : undefined}
              className={clsx(onRowClick && 'cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-800/50')}>
              {columns.map((c) => (
                <td key={c.key} className={clsx('px-4 sm:px-3', dense ? 'py-2' : 'py-3', c.align === 'right' ? 'text-right tabular-nums' : c.align === 'center' ? 'text-center' : 'text-left',
                  c.hideOnMobile && 'hidden md:table-cell', c.className)}>
                  {c.render ? c.render(r) : String((r as Record<string, unknown>)[c.key] ?? '')}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
        {footer && <tfoot className="border-t-2 border-gray-200 font-semibold dark:border-gray-700">{footer}</tfoot>}
      </table>
    </div>
  );
}

export function Pagination({ page, pageSize, total, onPage }: { page: number; pageSize: number; total: number; onPage: (p: number) => void }) {
  const { t } = useI18n();
  if (total <= pageSize) return null;
  const from = page * pageSize + 1;
  const to = Math.min(total, (page + 1) * pageSize);
  return (
    <div className="mt-4 flex items-center justify-between gap-3 text-sm text-ink-muted">
      <span>{t('common.showing', { from, to, total })}</span>
      <div className="flex gap-2">
        <Button size="sm" variant="outline" disabled={page === 0} onClick={() => onPage(page - 1)}>{t('common.previous')}</Button>
        <Button size="sm" variant="outline" disabled={to >= total} onClick={() => onPage(page + 1)}>{t('common.next')}</Button>
      </div>
    </div>
  );
}

export function UpgradeNotice({ feature, compact }: { feature: string; compact?: boolean }) {
  const { t } = useI18n();
  return (
    <Card className={clsx('border-dashed', compact ? '' : 'py-10')}>
      <div className="flex flex-col items-center gap-3 text-center">
        <div className="flex h-11 w-11 items-center justify-center rounded-xl bg-amber-50 text-amber-600 dark:bg-amber-900/30"><Lock className="h-5 w-5" /></div>
        <div>
          <p className="font-bold text-ink dark:text-white">{t('billing.upgradeTitle')}</p>
          <p className="mt-1 max-w-md text-sm text-ink-muted dark:text-gray-400">{t('billing.upgradeBody', { feature: t(`features.${feature}`) })}</p>
        </div>
        <LinkButton to="/app/billing" size="sm">{t('billing.seePlans')}</LinkButton>
      </div>
    </Card>
  );
}

export function KeyValue({ items, cols = 2 }: { items: { label: ReactNode; value: ReactNode }[]; cols?: 2 | 3 | 4 }) {
  return (
    <dl className={clsx('grid gap-x-6 gap-y-3', cols === 2 ? 'grid-cols-2' : cols === 3 ? 'grid-cols-2 md:grid-cols-3' : 'grid-cols-2 md:grid-cols-4')}>
      {items.map((i, idx) => (
        <div key={idx} className="min-w-0">
          <dt className="text-xs font-medium text-ink-muted dark:text-gray-400">{i.label}</dt>
          <dd className="mt-0.5 truncate text-sm font-semibold text-ink dark:text-gray-100">{i.value}</dd>
        </div>
      ))}
    </dl>
  );
}

export function SectionTitle({ children }: { children: ReactNode }) {
  return <h3 className="mb-3 text-sm font-bold uppercase tracking-wide text-ink-muted dark:text-gray-400">{children}</h3>;
}
