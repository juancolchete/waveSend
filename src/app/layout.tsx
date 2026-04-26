import type { Metadata } from "next";
import { Geist, Geist_Mono } from "next/font/google";
import "./globals.css";

const geistSans = Geist({
  variable: "--font-geist-sans",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: "WaveSend Wallet",
  description: "Send by waves",
};

export default function RootLayout({
  children,
}: Readonly<{
  children: React.ReactNode;
}>) {
  return (
    <html lang="en">
      <link rel="icon" href="/wavesendlogo.png" sizes="any" />
      <meta name="talentapp:project_verification" content="0ba5dcd141bae68d28f3018ac27fc3dc503c1ee175a13713047efbe7cc8835533c9dd9e1dabb7ecaf99f23dc02852257463c829e9146bc82934616a12cce2028" />
      <body
        className={`${geistSans.variable} ${geistMono.variable} antialiased`}
      >
        {children}
      </body>
    </html>
  );
}
