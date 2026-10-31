// Creator and promoter workspace: apply, share your link, see your numbers and balances, and request a payout.
// The server decides every amount; this page only shows it and asks.
import { FormEvent, useState } from 'react';
import { useQuery, useQueryClient } from '@tanstack/react-query';
import { BadgeCheck, Copy, Link2, Wallet } from 'lucide-react';
import { useI18n } from '../../i18n';
import { rpc } from '../../lib/api';
import { useAction } from '../../lib/useAction';
import { useToast } from '../../lib/toast';
import { siteOrigin } from '../../lib/market';
import { formatDate, formatDateTime } from '../../lib/format';
import { Alert, Badge, Button, Card, CardHeader, Field, Input, PageLoader, Select } from '../../components/ui';

const CHANNELS = ['tiktok', 'instagram', 'facebook', 'youtube', 'whatsapp', 'other'] as const;
const money = (n: number | string, lang: string) => `${Math.round(Number(n)).toLocaleString(lang === 'fr' ? 'fr-FR' : 'en-US').replace(/,/g, ' ')} FCFA`;

export default function CreatorPage() {
  const { t, lang } = useI18n();
  const { run, busy } = useAction();
  const toast = useToast();
  const qc = useQueryClient();
  const q = useQuery({ queryKey: ['creator-dashboard'], queryFn: () => rpc<any>('creator_dashboard') });
  const [apply, setApply] = useState({ display_name: '', bio: '', channels: [{ kind: 'tiktok', url: '' }] });
  const [payout, setPayout] = useState({ provider: 'mtn_momo', phone: '', name: '' });
  const [amount, setAmount] = useState('');
  if (q.isLoading) return <PageLoader />;
  if (q.error || !q.data) return <Alert tone="red">{t('creator.loadError')}</Alert>;
  const d = q.data;
  const refresh = () => { qc.invalidateQueries({ queryKey: ['creator-dashboard'] }); };

  const submitApply = async (e: FormEvent) => {
    e.preventDefault();
    const r = await run(() => rpc('creator_apply', { p: { display_name: apply.display_name, bio: apply.bio,
      channels: apply.channels.filter((c) => c.url.trim()), payout_provider: payout.provider, payout_phone: payout.phone,
      payout_name: payout.name } }), t('creator.applied'));
    if (r !== undefined) refresh();
  };
  const savePayout = async (e: FormEvent) => {
    e.preventDefault();
    const r = await run(() => rpc('creator_update', { p: { payout_provider: payout.provider, payout_phone: payout.phone, payout_name: payout.name } }), t('common.saved'));
    if (r !== undefined) refresh();
  };
  const request = async (e: FormEvent) => {
    e.preventDefault();
    const r = await run(() => rpc('creator_request_payout', { p_amount: Number(amount) }), t('creator.requested'));
    if (r !== undefined) { setAmount(''); refresh(); }
  };
  const cancel = async (id: string) => {
    const r = await run(() => rpc('creator_cancel_payout', { p_request: id }), t('creator.cancelled'));
    if (r !== undefined) refresh();
  };
  const copy = async (v: string) => { try { await navigator.clipboard.writeText(v); toast(t('market.copied'), 'success'); } catch { window.prompt('', v); } };

  if (!d.applied) {
    return (
      <div className="mx-auto max-w-2xl px-4 py-6">
        <h1 className="text-2xl font-extrabold">{t('creator.title')}</h1>
        <p className="mt-2 text-sm text-ink-muted">{t('creator.intro')}</p>
        <Card className="mt-6">
          <form onSubmit={submitApply} className="space-y-4">
            <Field label={t('creator.displayName')} required><Input maxLength={60} value={apply.display_name} onChange={(e) => setApply({ ...apply, display_name: e.target.value })} /></Field>
            <Field label={t('creator.bio')} optional><Input maxLength={300} value={apply.bio} onChange={(e) => setApply({ ...apply, bio: e.target.value })} /></Field>
            <div className="space-y-3 rounded-xl bg-gray-50 p-4 dark:bg-gray-900">
              <div><p className="text-sm font-semibold">{t('creator.payoutDetails')}</p><p className="text-xs text-ink-muted">{t('creator.payoutDetailsSub')}</p></div>
              <Field label={t('creator.provider')}>
                <Select value={payout.provider} onChange={(e) => setPayout({ ...payout, provider: e.target.value })}>
                  <option value="mtn_momo">MTN Mobile Money</option><option value="orange_money">Orange Money</option>
                </Select>
              </Field>
              <Field label={t('creator.phone')} required><Input type="tel" inputMode="tel" placeholder="6XX XX XX XX" value={payout.phone} onChange={(e) => setPayout({ ...payout, phone: e.target.value })} /></Field>
              <Field label={t('creator.accountName')} optional><Input maxLength={80} value={payout.name} onChange={(e) => setPayout({ ...payout, name: e.target.value })} /></Field>
            </div>
            <div className="space-y-2">
              <p className="text-sm font-semibold">{t('creator.channels')}</p>
              {apply.channels.map((c, i) => (
                <div key={i} className="grid grid-cols-[140px_minmax(0,1fr)] gap-2">
                  <Select aria-label={t('creator.channelKind')} value={c.kind} onChange={(e) => setApply({ ...apply, channels: apply.channels.map((x, j) => j === i ? { ...x, kind: e.target.value } : x) })}>
                    {CHANNELS.map((k) => <option key={k} value={k}>{t(`creator.channelKinds.${k}`)}</option>)}
                  </Select>
                  <Input type="url" placeholder="https://" aria-label={t('creator.channelUrl')} value={c.url}
                    onChange={(e) => setApply({ ...apply, channels: apply.channels.map((x, j) => j === i ? { ...x, url: e.target.value } : x) })} />
                </div>
              ))}
              {apply.channels.length < 5 && <Button type="button" variant="outline" size="sm" onClick={() => setApply({ ...apply, channels: [...apply.channels, { kind: 'other', url: '' }] })}>{t('creator.addChannel')}</Button>}
            </div>
            <Alert tone="blue">{t('creator.reviewNote')}</Alert>
            <Button type="submit" loading={busy} disabled={apply.display_name.trim().length < 2 || payout.phone.replace(/\D/g, '').length < 9}>{t('creator.apply')}</Button>
          </form>
        </Card>
      </div>
    );
  }

  const p = d.profile; const s = d.stats; const b = d.balance; const link = `${siteOrigin()}/?ref=${p.referral_code}`;
  const shareText = t('creator.shareText', { link });
  return (
    <div className="mx-auto max-w-5xl space-y-4 px-4 py-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="flex items-center gap-2 text-2xl font-extrabold"><BadgeCheck className="h-6 w-6 text-brand-600" />{p.display_name}</h1>
          <p className="text-sm text-ink-muted">{t('creator.title')}</p>
        </div>
        <Badge tone={p.status === 'approved' ? 'green' : p.status === 'pending' ? 'amber' : 'red'}>{t(`creator.status.${p.status}`)}</Badge>
      </div>

      {p.status === 'pending' && <Alert tone="amber" title={t('creator.pendingTitle')}>{t('creator.pendingBody')}</Alert>}
      {(p.status === 'rejected' || p.status === 'suspended') && (
        <Alert tone="red" title={t(`creator.status.${p.status}`)}>{p.decision_reason ?? t('creator.noReason')}</Alert>
      )}
      {p.status === 'approved' && !d.program.enabled && <Alert tone="blue">{t('creator.programClosed')}</Alert>}

      {p.status === 'approved' && (
        <>
          <Card>
            <CardHeader title={t('creator.yourLink')} subtitle={t('creator.linkSub')} />
            <div className="flex flex-col gap-2 sm:flex-row">
              <Input readOnly value={link} aria-label={t('creator.yourLink')} onFocus={(e) => e.currentTarget.select()} />
              <Button variant="outline" icon={<Copy className="h-4 w-4" />} onClick={() => copy(link)}>{t('creator.copyLink')}</Button>
            </div>
            <p className="mt-3 text-sm">{t('creator.codeLabel')}: <b className="font-mono tracking-widest">{p.referral_code}</b></p>
            <div className="mt-3 rounded-xl bg-gray-50 p-3 text-sm dark:bg-gray-800/60">
              <p className="mb-2 font-semibold">{t('creator.shareKit')}</p>
              <p>{shareText}</p>
              <Button size="sm" variant="outline" className="mt-2" icon={<Link2 className="h-4 w-4" />} onClick={() => copy(shareText)}>{t('creator.copyText')}</Button>
            </div>
          </Card>

          <div className="grid grid-cols-2 gap-3 md:grid-cols-5">
            {(['clicks', 'referrals', 'registered', 'paying'] as const).map((k) => (
              <Card key={k}><p className="text-xs text-ink-muted">{t(`creator.stats.${k}`)}</p><p className="text-2xl font-extrabold">{s[k]}</p></Card>
            ))}
            <Card><p className="text-xs text-ink-muted">{t('creator.stats.conversion')}</p><p className="text-2xl font-extrabold">{s.conversion_pct}%</p></Card>
          </div>

          <div className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_340px]">
            <Card>
              <CardHeader title={t('creator.balances')} subtitle={t('creator.commissionTerms', { rate: p.commission_rate, hold: d.program.hold_days })} />
              <dl className="grid grid-cols-2 gap-3 text-sm sm:grid-cols-3">
                <div><dt className="text-ink-muted">{t('creator.balance.pending')}</dt><dd className="text-lg font-bold">{money(b.pending, lang)}</dd></div>
                <div><dt className="text-ink-muted">{t('creator.balance.withdrawable')}</dt><dd className="text-lg font-bold">{money(b.withdrawable, lang)}</dd></div>
                <div><dt className="text-ink-muted">{t('creator.balance.reserved')}</dt><dd className="text-lg font-bold">{money(b.reserved, lang)}</dd></div>
                <div><dt className="text-ink-muted">{t('creator.balance.paid')}</dt><dd className="text-lg font-bold">{money(b.paid, lang)}</dd></div>
                <div><dt className="text-ink-muted">{t('creator.balance.reversed')}</dt><dd className="text-lg font-bold">{money(b.reversed, lang)}</dd></div>
              </dl>
              <p className="mt-4 text-xs text-ink-muted">{t('creator.terms')}</p>
            </Card>

            <Card>
              <CardHeader title={<span className="flex items-center gap-2"><Wallet className="h-4 w-4" />{t('creator.withdraw')}</span>} />
              {!p.payout_phone ? (
                <Alert tone="amber">{t('creator.needPayoutDetails')}</Alert>
              ) : (
                <form onSubmit={request} className="space-y-3">
                  <p className="text-sm">{t('creator.payoutTo', { provider: t(`methods.${p.payout_provider}`), phone: p.payout_phone })}</p>
                  <Field label={t('creator.amount')} hint={t('creator.minimum', { min: money(d.program.payout_minimum ?? 5000, lang) })}>
                    <Input inputMode="numeric" value={amount} onChange={(e) => setAmount(e.target.value.replace(/\D/g, ''))} />
                  </Field>
                  <Button type="submit" loading={busy} disabled={!amount || !d.program.enabled}>{t('creator.requestPayout')}</Button>
                  <p className="text-xs text-ink-muted">{t('creator.payoutNote')}</p>
                </form>
              )}
            </Card>
          </div>

          <Card>
            <CardHeader title={t('creator.payouts')} />
            {d.payouts.length === 0 ? <p className="text-sm text-ink-muted">{t('creator.noPayouts')}</p> : (
              <ul className="divide-y divide-gray-100 text-sm dark:divide-gray-800">
                {d.payouts.map((r: any) => (
                  <li key={r.id} className="flex flex-wrap items-center justify-between gap-2 py-2">
                    <span>{formatDateTime(r.requested_at, lang)} · {money(r.amount, lang)}{r.provider_reference && <span className="ml-2 font-mono text-xs">{r.provider_reference}</span>}</span>
                    <span className="flex items-center gap-2"><Badge tone={r.status === 'paid' ? 'green' : r.status === 'failed' || r.status === 'reversed' ? 'red' : 'amber'}>{t(`creator.payoutStatus.${r.status}`)}</Badge>
                      {r.status === 'requested' && <Button size="sm" variant="outline" onClick={() => cancel(r.id)}>{t('creator.cancelPayout')}</Button>}</span>
                  </li>
                ))}
              </ul>
            )}
          </Card>

          <Card>
            <CardHeader title={t('creator.ledger')} subtitle={t('creator.ledgerSub')} />
            {d.ledger.length === 0 ? <p className="text-sm text-ink-muted">{t('creator.noLedger')}</p> : (
              <ul className="divide-y divide-gray-100 text-sm dark:divide-gray-800">
                {d.ledger.map((l: any, i: number) => (
                  <li key={i} className="flex flex-wrap items-center justify-between gap-2 py-2">
                    <span>{formatDate(l.created_at, lang)} · {t(`creator.ledgerKind.${l.kind}`)}{l.payment_kind && ` (${t(`creator.paymentKind.${l.payment_kind}`)})`}</span>
                    <span className={Number(l.amount) < 0 ? 'font-semibold text-red-700' : 'font-semibold'}>{money(l.amount, lang)}</span>
                  </li>
                ))}
              </ul>
            )}
          </Card>
        </>
      )}

      {p.status !== 'rejected' && (
        <Card>
          <CardHeader title={t('creator.payoutDetails')} subtitle={t('creator.payoutDetailsSub')} />
          <form onSubmit={savePayout} className="grid gap-3 sm:grid-cols-3">
            <Field label={t('creator.provider')}>
              <Select value={payout.provider} onChange={(e) => setPayout({ ...payout, provider: e.target.value })}>
                <option value="mtn_momo">MTN Mobile Money</option><option value="orange_money">Orange Money</option>
              </Select>
            </Field>
            <Field label={t('creator.phone')} hint={p.payout_phone ? t('creator.currentPhone', { phone: p.payout_phone }) : undefined}>
              <Input type="tel" inputMode="tel" placeholder="6XX XX XX XX" value={payout.phone} onChange={(e) => setPayout({ ...payout, phone: e.target.value })} />
            </Field>
            <Field label={t('creator.accountName')} optional><Input maxLength={80} value={payout.name} onChange={(e) => setPayout({ ...payout, name: e.target.value })} /></Field>
            <div className="sm:col-span-3 flex justify-end"><Button type="submit" loading={busy} disabled={!payout.phone}>{t('common.save')}</Button></div>
          </form>
        </Card>
      )}
    </div>
  );
}
