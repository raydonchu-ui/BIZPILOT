// A creator's link (?ref=CODE) is kept on this device and counted as a visit, wherever it is opened. Once a signed-in
// account has a business, it is attached to that creator once. The server refuses self-referrals and a second
// attachment; the code is kept only when the attempt could not reach the server, so it is tried again later.
import { useEffect } from 'react';
import { useLocation } from 'react-router-dom';
import { useAuth } from '../lib/auth';
import { ApiError, rpc } from '../lib/api';

const KEY = 'bizpilot.ref';
const CODE = /^[A-Za-z0-9]{6,10}$/;

function storedCode(): string | null {
  try { return localStorage.getItem(KEY); } catch { return null; }
}
function forgetCode() {
  try { localStorage.removeItem(KEY); } catch { /* ignore */ }
}

export function CreatorReferral() {
  const { search } = useLocation();
  const { session, context } = useAuth();
  const hasBusiness = (context?.businesses.length ?? 0) > 0;

  useEffect(() => {
    const code = new URLSearchParams(search).get('ref');
    if (!code || !CODE.test(code)) return;
    try { localStorage.setItem(KEY, code.toUpperCase()); } catch { /* storage unavailable: still counted below */ }
    rpc('creator_track_click', { p_code: code }).catch(() => undefined);
  }, [search]);

  useEffect(() => {
    const code = session && hasBusiness ? storedCode() : null;
    if (!code) return;
    rpc('creator_attach_referral', { p_code: code }).then(forgetCode, (e) => { if (e instanceof ApiError) forgetCode(); });
  }, [session, hasBusiness]);

  return null;
}
