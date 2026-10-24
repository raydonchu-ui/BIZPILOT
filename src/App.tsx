import { lazy, ReactNode, Suspense } from 'react';
import { Navigate, Route, Routes, useLocation } from 'react-router-dom';
import { useAuth } from './lib/auth';
import { BusinessProvider } from './lib/business';
import { PageLoader } from './components/ui';
import { PublicLayout } from './components/layout/PublicLayout';
import { AppLayout } from './components/layout/AppLayout';
import { Home } from './pages/public/Home';
import { AboutPage, AiPage, AnalyticsPage, FaqPage, Features, HowItWorks, InventoryPage, PricingPage } from './pages/public/InfoPages';
import { LegalPage } from './pages/public/Legal';
import { ContactPage } from './pages/public/Contact';
import { AuthCallbackPage, ForgotPasswordPage, LoginPage, ResetPasswordPage, SignupPage } from './pages/auth/AuthPages';
import { AuthDiagnosticsPage } from './pages/auth/AuthDiagnostics';
import { OnboardingPage } from './pages/auth/Onboarding';
import { PwaPrompt } from './components/PwaPrompt';
import { StoreLockGate } from './components/StoreLock';

const Dashboard = lazy(() => import('./pages/app/Dashboard'));
const SetupChecklist = lazy(() => import('./pages/app/SetupChecklist'));
const ProductsPage = lazy(() => import('./pages/app/products/ProductsPage'));
const ProductForm = lazy(() => import('./pages/app/products/ProductForm'));
const CategoriesPage = lazy(() => import('./pages/app/products/CategoriesPage'));
const ProductDetail = lazy(() => import('./pages/app/products/ProductDetail'));
const InventoryPage2 = lazy(() => import('./pages/app/inventory/InventoryPage'));
const StockCountPage = lazy(() => import('./pages/app/inventory/StockCountPage'));
const ImportPage = lazy(() => import('./pages/app/inventory/ImportPage'));
const PurchasesPage = lazy(() => import('./pages/app/purchases/PurchasesPage'));
const PurchaseForm = lazy(() => import('./pages/app/purchases/PurchaseForm'));
const PurchaseDetail = lazy(() => import('./pages/app/purchases/PurchaseDetail'));
const SuppliersPage = lazy(() => import('./pages/app/parties/SuppliersPage'));
const SupplierDetail = lazy(() => import('./pages/app/parties/SupplierDetail'));
const CustomersPage = lazy(() => import('./pages/app/parties/CustomersPage'));
const CustomerDetail = lazy(() => import('./pages/app/parties/CustomerDetail'));
const SalesPage = lazy(() => import('./pages/app/sales/SalesPage'));
const NewSale = lazy(() => import('./pages/app/sales/NewSale'));
const SaleDetail = lazy(() => import('./pages/app/sales/SaleDetail'));
const ExpensesPage = lazy(() => import('./pages/app/money/ExpensesPage'));
const CashPage = lazy(() => import('./pages/app/money/CashPage'));
const ReportsPage = lazy(() => import('./pages/app/reports/ReportsPage'));
const AdvisorPage = lazy(() => import('./pages/app/reports/AdvisorPage'));
const StaffPage = lazy(() => import('./pages/app/settings/StaffPage'));
const SettingsPage = lazy(() => import('./pages/app/settings/SettingsPage'));
const BillingPage = lazy(() => import('./pages/app/settings/BillingPage'));
const ProfilePage = lazy(() => import('./pages/app/settings/ProfilePage'));
const NotificationsPage = lazy(() => import('./pages/app/NotificationsPage'));
const HelpPage = lazy(() => import('./pages/app/HelpPage'));
const MorePage = lazy(() => import('./pages/app/MorePage'));
const AdminApp = lazy(() => import('./pages/admin/AdminApp'));

// Signed-in area. Store Lock is checked first (the server refuses business data while locked);
// requirePin asks for a PIN to be created before the dashboard is shown for the first time.
function RequireAuth({ children, requirePin = true }: { children: ReactNode; requirePin?: boolean }) {
  const { session, ready } = useAuth();
  const loc = useLocation();
  if (!ready) return <PageLoader />;
  if (!session) return <Navigate to={`/login?next=${encodeURIComponent(loc.pathname + loc.search)}`} replace />;
  return <StoreLockGate requirePin={requirePin}><WithContext>{children}</WithContext></StoreLockGate>;
}

function WithContext({ children }: { children: ReactNode }) {
  const { contextLoading, context } = useAuth();
  if (contextLoading || context === undefined) return <PageLoader />;
  return <>{children}</>;
}

function AppShell() {
  return (
    <BusinessProvider fallback={<Navigate to="/onboarding" replace />}>
      <AppLayout />
    </BusinessProvider>
  );
}

function RequireAdmin({ children }: { children: ReactNode }) {
  const { context } = useAuth();
  if (!context?.is_platform_admin) return <Navigate to="/app" replace />;
  return <>{children}</>;
}

export function App() {
  return (
    <Suspense fallback={<PageLoader />}>
      <PwaPrompt />
      <Routes>
        <Route element={<PublicLayout />}>
          <Route index element={<Home />} />
          <Route path="features" element={<Features />} />
          <Route path="how-it-works" element={<HowItWorks />} />
          <Route path="inventory-management" element={<InventoryPage />} />
          <Route path="business-analytics" element={<AnalyticsPage />} />
          <Route path="ai-advisor" element={<AiPage />} />
          <Route path="pricing" element={<PricingPage />} />
          <Route path="about" element={<AboutPage />} />
          <Route path="faq" element={<FaqPage />} />
          <Route path="contact" element={<ContactPage />} />
          <Route path="privacy" element={<LegalPage doc="privacy" />} />
          <Route path="terms" element={<LegalPage doc="terms" />} />
          <Route path="billing-policy" element={<LegalPage doc="billing" />} />
        </Route>
        <Route path="login" element={<LoginPage />} />
        <Route path="signup" element={<SignupPage />} />
        <Route path="forgot-password" element={<ForgotPasswordPage />} />
        <Route path="reset-password" element={<ResetPasswordPage />} />
        <Route path="auth/callback" element={<AuthCallbackPage />} />
        <Route path="auth/diagnostics" element={<AuthDiagnosticsPage />} />
        <Route path="onboarding" element={<RequireAuth requirePin={false}><OnboardingPage /></RequireAuth>} />
        <Route path="onboarding/new" element={<RequireAuth requirePin={false}><OnboardingPage addAnother /></RequireAuth>} />
        <Route path="admin/*" element={<RequireAuth><RequireAdmin><AdminApp /></RequireAdmin></RequireAuth>} />
        <Route path="app" element={<RequireAuth><AppShell /></RequireAuth>}>
          <Route index element={<Dashboard />} />
          <Route path="setup" element={<SetupChecklist />} />
          <Route path="products" element={<ProductsPage />} />
          <Route path="products/new" element={<ProductForm />} />
          <Route path="products/categories" element={<CategoriesPage />} />
          <Route path="products/:id" element={<ProductDetail />} />
          <Route path="products/:id/edit" element={<ProductForm />} />
          <Route path="inventory" element={<InventoryPage2 />} />
          <Route path="inventory/counts" element={<InventoryPage2 initialTab="counts" />} />
          <Route path="inventory/counts/:id" element={<StockCountPage />} />
          <Route path="import" element={<ImportPage />} />
          <Route path="purchases" element={<PurchasesPage />} />
          <Route path="purchases/new" element={<PurchaseForm />} />
          <Route path="purchases/:id" element={<PurchaseDetail />} />
          <Route path="purchases/:id/edit" element={<PurchaseForm />} />
          <Route path="suppliers" element={<SuppliersPage />} />
          <Route path="suppliers/:id" element={<SupplierDetail />} />
          <Route path="customers" element={<CustomersPage />} />
          <Route path="customers/:id" element={<CustomerDetail />} />
          <Route path="sales" element={<SalesPage />} />
          <Route path="sales/new" element={<NewSale />} />
          <Route path="sales/:id" element={<SaleDetail />} />
          <Route path="expenses" element={<ExpensesPage />} />
          <Route path="cash" element={<CashPage />} />
          <Route path="reports" element={<ReportsPage />} />
          <Route path="advisor" element={<AdvisorPage />} />
          <Route path="staff" element={<StaffPage />} />
          <Route path="settings" element={<SettingsPage />} />
          <Route path="billing" element={<BillingPage />} />
          <Route path="profile" element={<ProfilePage />} />
          <Route path="notifications" element={<NotificationsPage />} />
          <Route path="help" element={<HelpPage />} />
          <Route path="more" element={<MorePage />} />
          <Route path="*" element={<Navigate to="/app" replace />} />
        </Route>
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </Suspense>
  );
}
