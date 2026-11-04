import { createMDX } from "fumadocs-mdx/next";
import path from "node:path";

const withMDX = createMDX();

/** @type {import('next').NextConfig} */
const config = {
  output: "export",
  trailingSlash: true,
  images: { unoptimized: true },
  reactStrictMode: true,
  allowedDevOrigins: ["10.0.0.2"],
  agentRules: false,
  turbopack: { root: path.resolve(import.meta.dirname, "..") },
};

export default withMDX(config);
