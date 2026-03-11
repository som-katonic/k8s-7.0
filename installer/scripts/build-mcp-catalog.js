#!/usr/bin/env node
/**
 * Build MCP server catalog entries from Docker Hub registry metadata.
 *
 * Scans a registry for images matching the mcp/* prefix and builds
 * catalog entries with inferred categories and input fields.
 *
 * Usage:
 *   node build-mcp-catalog.js [output.json]
 *
 * Environment:
 *   REGISTRY_URL  - Registry API base (default: https://hub.docker.com/v2)
 *   MCP_PREFIX    - Image prefix to scan (default: "mcp")
 */

const fs = require('fs');
const path = require('path');

const REGISTRY_URL = process.env.REGISTRY_URL || 'https://hub.docker.com/v2';
const MCP_PREFIX = process.env.MCP_PREFIX || 'mcp';
const OUTPUT_FILE = process.argv[2] || path.join(__dirname, '..', 'data', 'mcp-catalog.json');

const CATEGORY_KEYWORDS = {
  'Database': ['postgres', 'mysql', 'mongo', 'redis', 'sqlite', 'dynamodb', 'supabase', 'database', 'db'],
  'Communication': ['slack', 'email', 'smtp', 'teams', 'discord', 'telegram', 'twilio', 'sms', 'mail'],
  'Developer Tools': ['github', 'gitlab', 'jira', 'bitbucket', 'jenkins', 'ci', 'docker', 'kubernetes', 'npm'],
  'Search': ['search', 'google', 'bing', 'brave', 'elasticsearch', 'algolia', 'solr'],
  'CRM': ['salesforce', 'hubspot', 'crm', 'pipedrive', 'zoho'],
  'Storage': ['s3', 'gcs', 'azure-blob', 'dropbox', 'drive', 'box', 'storage', 'filesystem'],
  'Analytics': ['analytics', 'segment', 'mixpanel', 'amplitude', 'datadog', 'grafana', 'prometheus'],
  'AI/ML': ['openai', 'anthropic', 'huggingface', 'model', 'llm', 'embedding', 'vector'],
  'Project Management': ['asana', 'trello', 'notion', 'monday', 'linear', 'clickup'],
};

/**
 * Infer category from MCP server name.
 */
function inferCategory(name) {
  const lower = name.toLowerCase();
  for (const [category, keywords] of Object.entries(CATEGORY_KEYWORDS)) {
    for (const kw of keywords) {
      if (lower.includes(kw)) return category;
    }
  }
  return 'Uncategorized';
}

/**
 * Derive input fields from config keys.
 * Converts snake_case config keys into user-facing input field specs.
 */
function deriveInputFields(configKeys) {
  if (!configKeys || !Array.isArray(configKeys) || configKeys.length === 0) return [];

  return configKeys.map(key => {
    const isPassword = /password|secret|token|key|api_key/i.test(key);
    return {
      name: key,
      type: isPassword ? 'password' : 'text',
      required: true,
      placeholder: key.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase()),
    };
  });
}

/**
 * Build a single catalog entry from registry metadata.
 */
function buildCatalogEntry(repoData) {
  const name = repoData.name || '';
  const description = repoData.description || repoData.short_description || '';
  const pullCount = repoData.pull_count || repoData.pullCount || 0;
  const configKeys = repoData.config_keys || repoData.configKeys || [];
  const tools = repoData.tools || [];

  return {
    mcpName: name,
    dockerImage: `${MCP_PREFIX}/${name}`,
    category: inferCategory(name),
    description: description,
    tools: tools.map(t => typeof t === 'string' ? { name: t, description: '' } : t),
    inputFields: deriveInputFields(configKeys),
    pullCount: typeof pullCount === 'number' ? pullCount : 0,
  };
}

/**
 * Build full catalog from registry scan or input file.
 */
async function buildCatalog() {
  let repos;

  // Check if stdin has data (piped input)
  const stdinData = process.env.CATALOG_INPUT;
  if (stdinData) {
    repos = JSON.parse(stdinData);
  } else {
    // Try to fetch from registry
    try {
      const https = require('https');
      const url = `${REGISTRY_URL}/repositories/${MCP_PREFIX}/?page_size=100`;
      const data = await new Promise((resolve, reject) => {
        https.get(url, res => {
          let body = '';
          res.on('data', chunk => body += chunk);
          res.on('end', () => resolve(JSON.parse(body)));
          res.on('error', reject);
        }).on('error', reject);
      });
      repos = data.results || [];
    } catch (err) {
      console.error(`Cannot reach registry: ${err.message}`);
      console.error('Provide input via CATALOG_INPUT env var or pipe to stdin');
      process.exit(1);
    }
  }

  console.log(`Building catalog from ${repos.length} repositories`);

  const catalog = repos.map(buildCatalogEntry);

  // Ensure output directory exists
  const outDir = path.dirname(OUTPUT_FILE);
  if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, { recursive: true });

  fs.writeFileSync(OUTPUT_FILE, JSON.stringify(catalog, null, 2));
  console.log(`Wrote ${catalog.length} entries to ${OUTPUT_FILE}`);
}

// Export for testing
module.exports = { inferCategory, deriveInputFields, buildCatalogEntry };

// Run if called directly
if (require.main === module) {
  buildCatalog().catch(err => {
    console.error('Build failed:', err);
    process.exit(1);
  });
}
