import type { Metadata } from "next";
import "./globals.css";
import ClientRoot from "@/components/ClientRoot";
import { AppProvider } from "@/context/walletContext";
import "primereact/resources/themes/lara-light-cyan/theme.css";
import { StarknetProvider } from "@/components/utils/Provider";
import { Providers } from "./provider";

export const metadata: Metadata = {
  title: "Starkmate",
  description: "Starkmate — Chess on Starknet",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body className="antialiased font-rowdies bg-background text-foreground">
        <StarknetProvider>
          <AppProvider>
            <Providers>
            <ClientRoot>{children}</ClientRoot>
            </Providers>
          </AppProvider>
        </StarknetProvider>
      </body>
    </html>
  );
}
