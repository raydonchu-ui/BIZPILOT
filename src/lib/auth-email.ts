// Email handling for sign-up, sign-in and password reset. One address is one account, so every
// form writes the address the same way: trimmed and in lower case.

export function normalizeEmail(value: string): string {
  return value.trim().toLowerCase();
}

/** Supabase Auth reports an address that is already registered with one of these. */
export function isDuplicateSignup(err: unknown): boolean {
  const e = err as { code?: string; message?: string } | null;
  return e?.code === 'user_already_exists' || e?.code === 'email_exists' || /already (registered|exists)/i.test(e?.message ?? '');
}

/** Supabase Auth reports a wrong email or password with this code, and says nothing about which one was wrong. */
export function isInvalidLogin(err: unknown): boolean {
  const e = err as { code?: string; message?: string } | null;
  return e?.code === 'invalid_credentials' || /invalid login credentials/i.test(e?.message ?? '');
}
