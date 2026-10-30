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
import { CartProvider } from './lib/market';
import { MarketLayout } from './pages/market/MarketLayout';
import { MessagesPage, NotificationsPage as InboxPage, ThreadPage } from './pages/market/MessagesPages';
import { InboxListener } from './components/messaging';

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
const ManagerPage = lazy(() => import('./pages/app/manager/ManagerPage'));
const AutomationsPage = lazy(() => import('./pages/app/manager/AutomationsPage'));
const CreatorPage = lazy(() => import('./pages/market/CreatorPage'));
const StaffPage = lazy(() => import('./pages/app/settings/StaffPage'));
const SettingsPage = lazy(() => import('./pages/app/settings/SettingsPage'));
const BillingPage = lazy(() => import('./pages/app/settings/BillingPage'));
const ProfilePage = lazy(() => import('./pages/app/settings/ProfilePage'));
const NotificationsPage = lazy(() => import('./pages/app/NotificationsPage'));
const HelpPage = lazy(() => import('./pages/app/HelpPage'));
const MorePage = lazy(() => import('./pages/app/MorePage'));
const AdminApp = lazy(() => import('./pages/admin/AdminApp'));
const MyStorePage = lazy(() => import('./pages/app/store/MyStorePage'));
const SellerOrdersPage = lazy(() => import('./pages/app/store/OrdersPage'));
const SellerOrderDetail = lazy(() => import('./pages/app/store/OrdersPage').then((m) => ({ default: m.OrderDetailPage })));
const SellerPaymentsPage = lazy(() => import('./pages/app/store/PaymentsPromotions'));
const PromotionsPage = lazy(() => import('./pages/app/store/PaymentsPromotions').then((m) => ({ default: m.PromotionsPage })));
const MarketHome = lazy(() => import('./pages/market/MarketHome'));
const MarketSearch = lazy(() => import('./pages/market/MarketHome').then((m) => ({ default: m.SearchPage })));
const StorePage = lazy(() => import('./pages/market/StorePages').then((m) => ({ default: m.StorePage })));
const ProductPage = lazy(() => import('./pages/market/StorePages').then((m) => ({ default: m.ProductPage })));
const CartPage = lazy(() => import('./pages/market/CheckoutPages').then((m) => ({ default: m.CartPage })));
const CheckoutPage = lazy(() => import('./pages/market/CheckoutPages').then((m) => ({ default: m.CheckoutPage })));
const OrderPage = lazy(() => import('./pages/market/OrderPages').then((m) => ({ default: m.OrderPage })));
const PayReturnPage = lazy(() => import('./pages/market/OrderPages').then((m) => ({ default: m.PayReturnPage })));
const AccountPage = lazy(() => import('./pages/market/AccountPage'));
const ShopsPage = lazy(() => import('./pages/market/ShopsPage').then((m) => ({ default: m.ShopsPage })));
const MarketCategoriesPage = lazy(() => import('./pages/market/ShopsPage').then((m) => ({ default: m.CategoriesPage })));

// Signed-in area. Store Lock is checked first (the server refuses business data while locked);
// requirePin asks for a PIN to be created before the dashboard is shown for the first time.
function RequireAuth({ children, requirePin = false }: { children: ReactNode; requirePin?: boolean }) {
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
  const { session } = useAuth();
  // Buyers without a business go to their buyer account; anyone can start selling from there.
  const buyer = session?.user.user_metadata?.account_type === 'buyer';
  return (
    <BusinessProvider fallback={<Navigate to={buyer ? '/account' : '/onboarding'} replace />}>
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
    <CartProvider>
    <Suspense fallback={<PageLoader />}>
      <PwaPrompt />
      <InboxListener />
      <Routes>
        {/* BizPilot Market: public shopping (no Store Lock: shoppers' own data only). */}
        <Route element={<MarketLayout />}>
          <Route path="market" element={<MarketHome />} />
          <Route path="market/search" element={<MarketSearch />} />
          <Route path="market/shops" element={<ShopsPage />} />
          <Route path="market/categories" element={<MarketCategoriesPage />} />
          <Route path="s/:slug" element={<StorePage />} />
          <Route path="s/:slug/p/:id" element={<ProductPage />} />
          <Route path="cart" element={<CartPage />} />
          <Route path="checkout" element={<CheckoutPage />} />
          <Route path="order/:id" element={<OrderPage />} />
          <Route path="pay/return" element={<PayReturnPage />} />
          <Route path="account" element={<AccountPage />} />
          <Route path="creator" element={<RequireAuth requirePin={false}><CreatorPage /></RequireAuth>} />
          <Route path="messages" element={<RequireAuth requirePin={false}><MessagesPage /></RequireAuth>} />
          <Route path="messages/:id" element={<RequireAuth requirePin={false}><ThreadPage /></RequireAuth>} />
          <Route path="notifications" element={<RequireAuth requirePin={false}><InboxPage /></RequireAuth>} />
        </Route>
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
          <Route path="manager" element={<ManagerPage />} />
          <Route path="automations" element={<AutomationsPage />} />
          <Route path="staff" element={<StaffPage />} />
          <Route path="settings" element={<SettingsPage />} />
          <Route path="billing" element={<BillingPage />} />
          <Route path="profile" element={<ProfilePage />} />
          <Route path="notifications" element={<NotificationsPage />} />
          <Route path="help" element={<HelpPage />} />
          <Route path="more" element={<MorePage />} />
          <Route path="store" element={<MyStorePage />} />
          <Route path="orders" element={<SellerOrdersPage />} />
          <Route path="orders/:orderId" element={<SellerOrderDetail />} />
          <Route path="messages" element={<MessagesPage />} />
          <Route path="messages/:id" element={<ThreadPage />} />
          <Route path="payments" element={<SellerPaymentsPage />} />
          <Route path="promotions" element={<PromotionsPage />} />
          <Route path="*" element={<Navigate to="/app" replace />} />
        </Route>
        <Route path="*" element={<Navigate to="/" replace />} />
      </Routes>
    </Suspense>
    </CartProvider>
  );
}
