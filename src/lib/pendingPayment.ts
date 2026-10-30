// A Fapshi payment the customer left to pay on Fapshi's page. The app remembers it in this browser until the
// server has confirmed its status, so the payment is still checked when the customer comes back, even if
// the webhook from Fapshi never arrives.
const KEY = 'bizpilot.pendingPayment';

export function rememberPendingPayment(paymentId: string) {
  try { localStorage.setItem(KEY, JSON.stringify({ id: paymentId, at: Date.now() })); } catch { /* private mode: nothing to remember */ }
}

export function pendingPayment(): string | null {
  try {
    const v = JSON.parse(localStorage.getItem(KEY) ?? 'null');
    return typeof v?.id === 'string' ? v.id : null;
  } catch { return null; }
}

export function clearPendingPayment() {
  try { localStorage.removeItem(KEY); } catch { /* ignore */ }
}
