'use client';

import "./globals.css";
import "@rainbow-me/rainbowkit/styles.css";
import { Providers } from "./providers";
import { Toaster } from 'sonner';
import { ThemeProvider } from "../context/ThemeContext";
import { FloatingAIChat } from "../components/ui/FloatingAIChat";
import StatusHUD from "../components/StatusHUD";

export default function RootLayout({ children }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <title>FAO | Futarchy Autonomous Optimizer</title>
        <meta name="description" content="The future of governance. Award winning design." />
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="anonymous" />
        <link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Mono:wght@400;700&family=Press+Start+2P&display=swap" rel="stylesheet" />
      </head>
      <body className="font-mono antialiased">
        <ThemeProvider>
          <Providers>
            <div className="app-shell">
              <div className="app-scroll">
                {children}
              </div>
              {/* <FloatingAIChat /> */}
              <StatusHUD />
              <Toaster position="bottom-right" />
            </div>
          </Providers>
        </ThemeProvider>
      </body>
    </html>
  );
}

