import { describe, expect, it } from 'vitest';
import { formatOmr, muscatToday } from './money';

describe('formatOmr', () => {
  it('يعرض ثلاث خانات للبيسة', () => {
    expect(formatOmr(116000)).toBe('116.000');
    expect(formatOmr(5523)).toBe('5.523');
    expect(formatOmr(5)).toBe('0.005');
    expect(formatOmr(0)).toBe('0.000');
    expect(formatOmr(1234567890)).toBe('1,234,567.890');
    expect(formatOmr(-4500)).toBe('-4.500');
    expect(formatOmr(null)).toBe('—');
  });
});

describe('muscatToday', () => {
  it('ينتقل لليوم التالي عند منتصف ليل مسقط لا UTC', () => {
    expect(muscatToday(new Date('2026-11-26T19:59:00Z'))).toBe('2026-11-26');
    expect(muscatToday(new Date('2026-11-26T20:00:00Z'))).toBe('2026-11-27');
  });
});
