/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'export',
  trailingSlash: true,
  images: { unoptimized: true },
  // next dev would otherwise append its own block to AGENTS.md on every start
  agentRules: false,
};

export default nextConfig;
