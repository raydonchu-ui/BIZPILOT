import { FormEvent, useState } from 'react';
import { useQuery } from '@tanstack/react-query';
import { Mail, MessageCircle, Phone } from 'lucide-react';
import { useI18n } from '../../i18n';
import { Alert, Button, Card, Field, Input, Select, Textarea } from '../../components/ui';
import { rpc, unwrap } from '../../lib/api';
import { supabase } from '../../lib/supabase';
import { errorMessage } from '../../lib/errors';
import { useAuth } from '../../lib/auth';

export function useSupportContact() {
  return useQuery({
    queryKey: ['support_contact'],
    queryFn: async () => (unwrap(await supabase.from('app_config').select('value').eq('key', 'support_contact').maybeSingle()) as any)?.value
      ?? {},
  });
}

export function SupportForm({ businessId, compact }: { businessId?: string; compact?: boolean }) {
  const { t, tv, has } = useI18n();
  const { context } = useAuth();
  const [form, setForm] = useState({ name: '', email: '', phone: '', category: 'question', subject: '', message: '' });
  const [state, setState] = useState<'idle' | 'sending' | 'sent'>('idle');
  const [error, setError] = useState<string | null>(null);
  const cats = tv<Record<string, string>>('site.contact.categories');
  const set = (k: string) => (e: { target: { value: string } }) => setForm((f) => ({ ...f, [k]: e.target.value }));
  const submit = async (e: FormEvent) => {
    e.preventDefault();
    setError(null);
    setState('sending');
    try {
      await rpc('submit_support_request', { p: { ...form, business_id: businessId } });
      setState('sent');
    } catch (err) {
      setError(errorMessage(err, t, has));
      setState('idle');
    }
  };
  if (state === 'sent') return <Alert tone="green">{t('site.contact.sent')}</Alert>;
  return (
    <form onSubmit={submit} className="space-y-4">
      {!context && (
        <div className="grid gap-4 sm:grid-cols-2">
          <Field label={t('common.name')}><Input value={form.name} onChange={set('name')} autoComplete="name" /></Field>
          <Field label={t('common.email')} required><Input type="email" required value={form.email} onChange={set('email')} autoComplete="email" /></Field>
        </div>
      )}
      <div className={compact ? 'space-y-4' : 'grid gap-4 sm:grid-cols-2'}>
        <Field label={t('site.contact.category')}>
          <Select value={form.category} onChange={set('category')}>
            {Object.entries(cats).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
          </Select>
        </Field>
        <Field label={t('site.contact.subject')} required><Input required minLength={3} maxLength={150} value={form.subject} onChange={set('subject')} /></Field>
      </div>
      <Field label={t('site.contact.message')} required><Textarea required minLength={5} maxLength={5000} rows={6} value={form.message} onChange={set('message')} /></Field>
      {error && <Alert tone="red">{error}</Alert>}
      <Button type="submit" loading={state === 'sending'}>{t('site.contact.send')}</Button>
    </form>
  );
}

export function ContactPage() {
  const { t } = useI18n();
  const { data: contact } = useSupportContact();
  const hasDirect = contact && (contact.email || contact.phone || contact.whatsapp);
  return (
    <div className="mx-auto grid max-w-5xl gap-8 px-4 py-14 sm:px-6 lg:grid-cols-3">
      <div className="lg:col-span-2">
        <h1 className="text-4xl font-extrabold tracking-tight">{t('site.contact.title')}</h1>
        <p className="mt-2 text-ink-soft dark:text-gray-300">{t('site.contact.subtitle')}</p>
        <Card className="mt-8"><h2 className="mb-4 text-lg font-bold">{t('site.contact.formTitle')}</h2><SupportForm /></Card>
      </div>
      <Card className="h-fit">
        <h2 className="font-bold">{t('site.contact.direct')}</h2>
        {hasDirect ? (
          <ul className="mt-3 space-y-3 text-sm">
            {contact.email && <li className="flex items-center gap-2"><Mail className="h-4 w-4 text-brand-600" /><a href={`mailto:${contact.email}`} className="hover:underline">{contact.email}</a></li>}
            {contact.phone && <li className="flex items-center gap-2"><Phone className="h-4 w-4 text-brand-600" />{contact.phone}</li>}
            {contact.whatsapp && <li className="flex items-center gap-2"><MessageCircle className="h-4 w-4 text-brand-600" />WhatsApp {contact.whatsapp}</li>}
          </ul>
        ) : <p className="mt-2 text-sm text-ink-muted">{t('site.contact.noDirect')}</p>}
      </Card>
    </div>
  );
}
