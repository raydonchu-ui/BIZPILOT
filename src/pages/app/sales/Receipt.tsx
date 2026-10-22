import { useI18n } from '../../../i18n';
import { formatDateTime, formatMoney, formatNumber } from '../../../lib/format';

export function Receipt({ sale, business, settings, payments }: { sale: any; business: any; settings: any; payments: any[] }) {
  const { t, lang } = useI18n();
  const m = (v: number) => formatMoney(v, lang, business.currency);
  return (
    <div className="mx-auto w-full max-w-[380px] bg-white p-5 font-mono text-[12px] leading-relaxed text-black" id="receipt">
      <div className="text-center">
        <p className="text-base font-bold">{business.name}</p>
        {business.address && <p>{business.address}{business.city ? `, ${business.city}` : ''}</p>}
        {business.phone && <p>{t('common.phone')}: {business.phone}</p>}
        {business.tax_id && <p>NIU: {business.tax_id}</p>}
        {business.trade_register && <p>RCCM: {business.trade_register}</p>}
        {settings?.receipt_header && <p className="mt-1 whitespace-pre-line">{settings.receipt_header}</p>}
      </div>
      <div className="my-2 border-t border-dashed border-black" />
      <p>{t('receipt.number')}: {sale.number}</p>
      <p>{t('common.date')}: {formatDateTime(sale.sold_at, lang, business.timezone)}</p>
      {sale.customers?.name && <p>{t('pos.customer')}: {sale.customers.name}</p>}
      <div className="my-2 border-t border-dashed border-black" />
      <table className="w-full">
        <tbody>
          {sale.sale_lines.map((l: any) => (
            <tr key={l.id} className="align-top">
              <td className="pb-1 pr-2">{l.products?.name}<br /><span className="text-[11px]">{formatNumber(l.quantity, lang)} {l.unit_name} × {formatNumber(l.unit_price, lang)}{Number(l.line_discount) > 0 ? ` − ${formatNumber(l.line_discount, lang)}` : ''}</span></td>
              <td className="pb-1 text-right">{formatNumber(Number(l.net_amount) + Number(l.sale_discount_alloc), lang)}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <div className="my-2 border-t border-dashed border-black" />
      {Number(sale.sale_discount) > 0 && <p className="flex justify-between"><span>{t('pos.saleDiscount')}</span><span>− {m(sale.sale_discount)}</span></p>}
      <p className="flex justify-between text-sm font-bold"><span>{t('common.total')}</span><span>{m(sale.total)}</span></p>
      {Number(sale.tax_total) > 0 && <p className="flex justify-between"><span>{t('receipt.taxIncluded', { label: settings?.tax_label ?? 'TVA' })}</span><span>{m(sale.tax_total)}</span></p>}
      {payments.map((p) => <p key={p.id} className="flex justify-between"><span>{t(`methods.${p.method}`)}{p.reference ? ` (${p.reference})` : ''}</span><span>{p.direction === 'out' ? '− ' : ''}{m(p.amount)}</span></p>)}
      {Number(sale.returned_total) > 0 && <p className="flex justify-between"><span>{t('receipt.returned')}</span><span>− {m(sale.returned_total)}</span></p>}
      {(() => { const owed = Number(sale.total) - Number(sale.returned_total) + Number(sale.refunded_total) - Number(sale.paid_total); return owed > 0 ? <p className="flex justify-between font-bold"><span>{t('receipt.balanceDue')}</span><span>{m(owed)}</span></p> : null; })()}
      <div className="my-2 border-t border-dashed border-black" />
      <p className="whitespace-pre-line text-center">{settings?.receipt_footer ?? ''}</p>
      <p className="mt-2 text-center text-[10px]">{t('receipt.poweredBy')}</p>
    </div>
  );
}
