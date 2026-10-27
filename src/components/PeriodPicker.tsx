import { useState } from 'react';
import { CalendarDays } from 'lucide-react';
import { useI18n } from '../i18n';
import { Period, PeriodKey, periodRange } from '../lib/dates';
import { formatDate } from '../lib/format';
import { useBiz } from '../lib/business';
import { Button, Input, Modal, Select } from './ui';

const KEYS: PeriodKey[] = ['today', 'yesterday', 'this_week', 'last_7', 'this_month', 'last_month', 'last_30', 'last_90', 'this_year', 'custom'];

export function usePeriod(initial: PeriodKey = 'this_month') {
  const { biz } = useBiz();
  const storageKey = 'bizpilot.period';
  const [period, setPeriod] = useState<Period>(() => {
    try {
      const s = JSON.parse(sessionStorage.getItem(storageKey) ?? 'null');
      if (s?.key) return s.key === 'custom' ? s : periodRange(s.key, biz.timezone);
    } catch { /* ignore */ }
    return periodRange(initial, biz.timezone);
  });
  const update = (p: Period) => {
    setPeriod(p);
    try { sessionStorage.setItem(storageKey, JSON.stringify(p)); } catch { /* ignore */ }
  };
  return [period, update] as const;
}

export function PeriodPicker({ value, onChange }: { value: Period; onChange: (p: Period) => void }) {
  const { t, lang } = useI18n();
  const { biz } = useBiz();
  const [custom, setCustom] = useState(false);
  const [from, setFrom] = useState(value.from);
  const [to, setTo] = useState(value.to);
  return (
    <div className="flex items-center gap-2 rounded-xl border border-gray-200 bg-white px-3 py-1.5 shadow-xs dark:border-gray-800 dark:bg-gray-900">
      <CalendarDays className="h-5 w-5 shrink-0 text-ink-soft dark:text-gray-300" />
      <div className="min-w-0">
        <Select aria-label={t('common.period')} value={value.key} className="!h-7 border-0 !px-0 !pr-6 font-semibold shadow-none focus:ring-0 dark:bg-gray-900"
          onChange={(e) => {
            const k = e.target.value as PeriodKey;
            if (k === 'custom') { setFrom(value.from); setTo(value.to); setCustom(true); } else onChange(periodRange(k, biz.timezone));
          }}>
          {KEYS.map((k) => <option key={k} value={k}>{t(`periods.${k}`)}</option>)}
        </Select>
        <p className="-mt-0.5 truncate text-[11px] text-ink-muted dark:text-gray-400">{formatDate(value.from, lang)} – {formatDate(value.to, lang)}</p>
      </div>
      <Modal open={custom} onClose={() => setCustom(false)} title={t('periods.custom')} size="sm"
        footer={<><Button variant="outline" onClick={() => setCustom(false)}>{t('common.cancel')}</Button>
          <Button disabled={!from || !to || from > to} onClick={() => { onChange({ key: 'custom', from, to }); setCustom(false); }}>{t('common.apply')}</Button></>}>
        <div className="grid grid-cols-2 gap-3">
          <label className="text-sm">{t('common.from')}<Input type="date" value={from} max={to} onChange={(e) => setFrom(e.target.value)} /></label>
          <label className="text-sm">{t('common.to')}<Input type="date" value={to} min={from} onChange={(e) => setTo(e.target.value)} /></label>
        </div>
      </Modal>
    </div>
  );
}
