export interface BranchCtx {
  id: string; organization_id: string; code: string; name_ar: string;
  tax_enabled: boolean; tax_rate_bp: number; prices_include_tax: boolean;
  roles: string[]; permissions: string[]; max_discount_bp: number;
}
export interface Ctx { user: { id: string; full_name: string } | null; branches: BranchCtx[] }

export interface InvoiceRow {
  id: string; invoice_no: string; status: 'approved' | 'voided'; approved_at: string; business_date: string;
  branch_id: string; branch_code: string; branch_name_ar: string;
  total_baisa: number; tax_baisa: number; discount_baisa: number; cash_baisa: number; card_baisa: number;
  cashier_name: string; customer_name: string | null; customer_phone: string | null; plate: string | null;
}

export interface InvoiceLine {
  line_no: number; sku: string; kind: string; description_ar: string; unit: string; qty: number;
  unit_price_baisa: number; gross_baisa: number; discount_baisa: number; net_baisa: number; tax_baisa: number; total_baisa: number;
}
export interface Invoice {
  id: string; invoice_no: string; status: string; approved_at: string; business_date: string; branch_id: string;
  branch: { code: string; name_ar: string }; cashier_name: string;
  customer: { name: string; phone: string | null } | null; vehicle: { plate: string; make: string | null; model: string | null } | null;
  tax_rate_bp: number; prices_include_tax: boolean;
  subtotal_baisa: number; discount_baisa: number; net_baisa: number; tax_baisa: number; total_baisa: number;
  paid_baisa: number; change_baisa: number; note: string | null; print_count: number;
  lines: InvoiceLine[];
  payments: { method: 'cash' | 'card'; amount_baisa: number; tendered_baisa: number | null; card_reference: string | null }[];
}

export interface Summary {
  invoice_count: number; net_sales_baisa: number; tax_baisa: number; total_baisa: number; discount_baisa: number;
  cash_baisa: number; card_baisa: number; gross_profit_baisa: number | null;
}

export const can = (ctx: Ctx, perm: string, branchId?: string | null) =>
  ctx.branches.some((b) => (!branchId || b.id === branchId) && b.permissions.includes(perm));
