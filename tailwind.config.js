/** @type {import('tailwindcss').Config} */
export default {
  content: ['./index.html', './src/**/*.{ts,tsx}'],
  darkMode: 'class',
  theme: {
    extend: {
      fontFamily: { sans: ['"Plus Jakarta Sans"', 'system-ui', '-apple-system', 'Segoe UI', 'Roboto', 'sans-serif'] },
      colors: {
        brand: {
          50: '#eefbf1', 100: '#d6f5de', 200: '#afe9c0', 300: '#7dd79b', 400: '#47bd6f', 500: '#24a04f',
          600: '#18813e', 700: '#156834', 800: '#14522c', 900: '#0f3f24', 950: '#08261a',
        },
        ink: { DEFAULT: '#111827', soft: '#374151', muted: '#6b7280' },
      },
      boxShadow: { card: '0 1px 2px rgba(16,24,40,.04), 0 1px 3px rgba(16,24,40,.06)' },
    },
  },
  plugins: [],
};
