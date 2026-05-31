/** @type {import('next').NextConfig} */
const nextConfig = {
  // .app bundle içinde file:// üzerinden servis edilecek static dosyalar.
  // Swift kabuk WKWebView'a bu klasörü yükler; SSR/Node sidecar yok.
  output: "export",

  // file:// scheme'de Next image optimizer çalışmaz → bypass
  images: { unoptimized: true },

  reactStrictMode: true,

  // Static export'ta her sayfa kendi klasöründe index.html olarak çıksın
  // (file:// altında düzgün resolve olur)
  trailingSlash: true,
};

export default nextConfig;
