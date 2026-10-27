import { describe, expect, it } from 'vitest';
import { isDuplicateSignup, isInvalidLogin, normalizeEmail } from './auth-email';

describe('normalizeEmail', () => {
  it('makes the same address the same account regardless of case or spaces', () => {
    expect(normalizeEmail('  Ada.Mballa@Mail.COM ')).toBe('ada.mballa@mail.com');
    expect(normalizeEmail('ada.mballa@mail.com')).toBe(normalizeEmail('ADA.MBALLA@mail.com '));
  });
});

describe('duplicate and invalid login detection', () => {
  it('recognises an already registered address by code or message', () => {
    expect(isDuplicateSignup({ code: 'user_already_exists' })).toBe(true);
    expect(isDuplicateSignup({ code: 'email_exists' })).toBe(true);
    expect(isDuplicateSignup({ message: 'User already registered' })).toBe(true);
    expect(isDuplicateSignup({ code: 'weak_password', message: 'Password too short' })).toBe(false);
    expect(isDuplicateSignup(null)).toBe(false);
  });

  it('recognises a failed login without revealing which part was wrong', () => {
    expect(isInvalidLogin({ code: 'invalid_credentials' })).toBe(true);
    expect(isInvalidLogin({ message: 'Invalid login credentials' })).toBe(true);
    expect(isInvalidLogin({ code: 'email_not_confirmed' })).toBe(false);
  });
});
