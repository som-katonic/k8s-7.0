#!/usr/bin/env node
/**
 * Seed MCP server catalog into MongoDB.
 *
 * Reads the MCP catalog JSON and upserts entries into the mcp_servers
 * collection. Handles image path rewriting for private registries
 * and tracks platform version for upgrade diffing.
 *
 * Usage:
 *   MONGO_URI=mongodb://... PRIVATE_REGISTRY=harbor.internal node seed-mcp-catalog.js catalog.json
 *
 * Environment:
 *   MONGO_URI           - MongoDB connection string (default: mongodb://localhost:27017/katonic)
 *   PRIVATE_REGISTRY    - Private registry prefix for air-gap (default: "mcp")
 *   PLATFORM_VERSION    - Version stamp for tracking (default: "7.0.0")
 */

const fs = require('fs');
const path = require('path');

const MONGO_URI = process.env.MONGO_URI || 'mongodb://localhost:27017/katonic';
const PRIVATE_REGISTRY = process.env.PRIVATE_REGISTRY || '';
const PLATFORM_VERSION = process.env.PLATFORM_VERSION || '7.0.0';
const CATALOG_FILE = process.argv[2] || path.join(__dirname, 'mcp-catalog.json');

/**
 * Rewrite a docker image path for the target registry.
 *
 * @param {string} originalImage - e.g. "mcp/atlassian"
 * @param {string} registry - e.g. "harbor.internal" or "" for default
 * @returns {string} - e.g. "harbor.internal/mcp/atlassian"
 */
function rewriteImagePath(originalImage, registry) {
  if (!registry || registry === '') {
    return originalImage;
  }
  // Trim trailing slash to prevent double-slash bug
  const cleanRegistry = registry.replace(/\/+$/, '');
  return `${cleanRegistry}/${originalImage}`;
}

/**
 * Seed catalog entries into MongoDB.
 */
async function seedCatalog() {
  let mongoose;
  try {
    mongoose = require('mongoose');
  } catch (e) {
    console.error('mongoose not installed. Run: npm install mongoose');
    process.exit(1);
  }

  // Read catalog
  if (!fs.existsSync(CATALOG_FILE)) {
    console.error(`Catalog file not found: ${CATALOG_FILE}`);
    process.exit(1);
  }

  const catalog = JSON.parse(fs.readFileSync(CATALOG_FILE, 'utf-8'));
  console.log(`Catalog: ${catalog.length} entries from ${CATALOG_FILE}`);
  console.log(`Registry: ${PRIVATE_REGISTRY || '(default)'}`);
  console.log(`Version: ${PLATFORM_VERSION}`);

  if (catalog.length === 0) {
    console.log('Empty catalog, nothing to seed.');
    return;
  }

  // Connect
  await mongoose.connect(MONGO_URI);
  console.log(`Connected to MongoDB`);

  // Define schema
  const mcpServerSchema = new mongoose.Schema({
    mcpName: { type: String, required: true, unique: true },
    dockerImage: { type: String, required: true },
    category: { type: String, default: 'Uncategorized' },
    description: String,
    tools: [{ name: String, description: String }],
    inputFields: [{ name: String, type: String, required: Boolean, placeholder: String }],
    platformVersion: String,
    updatedAt: { type: Date, default: Date.now },
  }, { timestamps: true });

  const McpServer = mongoose.models.McpServer || mongoose.model('McpServer', mcpServerSchema, 'mcp_servers');

  // Upsert each entry
  let created = 0;
  let updated = 0;

  for (const entry of catalog) {
    const dockerImage = rewriteImagePath(entry.dockerImage, PRIVATE_REGISTRY);

    const result = await McpServer.findOneAndUpdate(
      { mcpName: entry.mcpName },
      {
        $set: {
          dockerImage,
          category: entry.category || 'Uncategorized',
          description: entry.description || '',
          tools: entry.tools || [],
          inputFields: entry.inputFields || [],
          platformVersion: PLATFORM_VERSION,
          updatedAt: new Date(),
        },
      },
      { upsert: true, new: true, setDefaultsOnInsert: true }
    );

    if (result.createdAt && result.updatedAt &&
        Math.abs(result.createdAt.getTime() - result.updatedAt.getTime()) < 1000) {
      created++;
    } else {
      updated++;
    }
  }

  console.log(`\nResults: ${created} created, ${updated} updated`);
  await mongoose.disconnect();
}

// Export for testing
module.exports = { rewriteImagePath, seedCatalog };

// Run if called directly
if (require.main === module) {
  seedCatalog().catch(err => {
    console.error('Seed failed:', err);
    process.exit(1);
  });
}
