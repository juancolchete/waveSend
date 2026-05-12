import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: "export", // Forces Next.js to build to an 'out' folder
  images: {
    unoptimized: true, // Native apps can't use Next.js server-side image optimization
  },
  trailingSlash: true, // Prevents routing bugs in Capacitor WebViews
};

export default nextConfig;
