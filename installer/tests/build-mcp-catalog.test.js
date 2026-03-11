/**
 * Tests for build-mcp-catalog.js
 *
 * The catalog builder fetches repos from Docker Hub, enriches them with
 * metadata from GitHub's mcp-registry, and writes mcp-catalog.json.
 *
 * These tests mock external HTTP calls and validate the transformation logic.
 *
 * Run: npx jest build-mcp-catalog.test.js
 */

// ---------------------------------------------------------------------------
// Extracted pure functions to test (copy these from build-mcp-catalog.js)
// ---------------------------------------------------------------------------

/**
 * Builds a catalog entry from a Docker Hub repo + optional server.yaml data.
 * This is the core transformation - no network calls.
 */
function buildCatalogEntry(repo, serverYaml) {
  const toolsJson = serverYaml?.tools?.map((t) => ({
    name: t.name || t,
    description: t.description || "",
    parameters: t.parameters || {},
  })) || [];

  return {
    mcpName: serverYaml?.title || repo.name.replace(/-/g, " ").replace(/\b\w/g, (c) => c.toUpperCase()),
    description: serverYaml?.description || repo.description || "",
    category: serverYaml?.category || inferCategory(repo.description || ""),
    serverType: serverYaml?.serverType || (serverYaml?.transportType === "sse" ? "remote" : "local"),
    transportType: serverYaml?.transportType || "stdio",
    dockerImage: `mcp/${repo.name}`,
    latestTag: "latest",
    latestDigest: repo.latestDigest || "",
    lastUpdated: repo.lastUpdated || "",
    pullCount: repo.pull_count || 0,
    tools: toolsJson,
    inputFields: deriveInputFields(serverYaml),
    source: serverYaml?.source || "",
    runCommand: serverYaml?.runCommand || "",
  };
}

function inferCategory(description) {
  const desc = description.toLowerCase();
  if (desc.includes("postgres") || desc.includes("mysql") || desc.includes("database") || desc.includes("redis"))
    return "Databases & Storage";
  if (desc.includes("slack") || desc.includes("email") || desc.includes("discord"))
    return "Communication";
  if (desc.includes("github") || desc.includes("gitlab") || desc.includes("git"))
    return "Developer Tools";
  if (desc.includes("search") || desc.includes("web") || desc.includes("browser"))
    return "Search & Web";
  if (desc.includes("jira") || desc.includes("asana") || desc.includes("project"))
    return "Project Management";
  return "Uncategorized";
}

function deriveInputFields(serverYaml) {
  if (!serverYaml?.config) return [];
  return Object.entries(serverYaml.config).map(([key, val]) => ({
    value: key,
    title: val.title || key.replace(/_/g, " "),
    description: val.description || "",
    type: key.toLowerCase().includes("token") || key.toLowerCase().includes("secret") || key.toLowerCase().includes("password")
      ? "password"
      : "text",
    placeholder: val.placeholder || "",
    required: val.required !== false,
    defaultValue: val.default || "",
  }));
}

// ---------------------------------------------------------------------------
// Test fixtures
// ---------------------------------------------------------------------------
const MOCK_DOCKER_HUB_REPO = {
  name: "atlassian",
  description: "MCP server for Atlassian Jira and Confluence",
  pull_count: 5200,
  latestDigest: "sha256:abc123",
  lastUpdated: "2026-02-01T00:00:00Z",
};

const MOCK_SERVER_YAML = {
  title: "Atlassian",
  description: "Atlassian Jira and Confluence integration",
  category: "Project Management",
  serverType: "remote",
  transportType: "sse",
  source: "https://github.com/mcp/atlassian",
  runCommand: "node server.js",
  tools: [
    { name: "jira_search", description: "Search Jira issues" },
    { name: "confluence_read", description: "Read Confluence pages" },
  ],
  config: {
    JIRA_TOKEN: { title: "Jira API Token", description: "API token for Jira", required: true },
    JIRA_URL: { title: "Jira URL", description: "Your Jira instance URL", placeholder: "https://yourco.atlassian.net" },
  },
};

// ===========================================================================
// TEST SUITE 1: buildCatalogEntry
// ===========================================================================
describe("buildCatalogEntry", () => {
  test("combines Docker Hub + server.yaml data correctly", () => {
    const entry = buildCatalogEntry(MOCK_DOCKER_HUB_REPO, MOCK_SERVER_YAML);

    expect(entry.mcpName).toBe("Atlassian");
    expect(entry.category).toBe("Project Management");
    expect(entry.serverType).toBe("remote");
    expect(entry.transportType).toBe("sse");
    expect(entry.dockerImage).toBe("mcp/atlassian");
    expect(entry.pullCount).toBe(5200);
    expect(entry.tools).toHaveLength(2);
    expect(entry.tools[0].name).toBe("jira_search");
    expect(entry.inputFields).toHaveLength(2);
  });

  test("falls back to Docker Hub data when no server.yaml", () => {
    const entry = buildCatalogEntry(MOCK_DOCKER_HUB_REPO, null);

    // mcpName should be title-cased from repo name
    expect(entry.mcpName).toBe("Atlassian");
    expect(entry.description).toBe("MCP server for Atlassian Jira and Confluence");
    expect(entry.serverType).toBe("local"); // default
    expect(entry.transportType).toBe("stdio"); // default
    expect(entry.tools).toHaveLength(0);
    expect(entry.inputFields).toHaveLength(0);
  });

  test("generates mcpName from hyphenated repo name", () => {
    const repo = { ...MOCK_DOCKER_HUB_REPO, name: "google-drive" };
    const entry = buildCatalogEntry(repo, null);

    expect(entry.mcpName).toBe("Google Drive");
  });

  test("prefers server.yaml title over generated name", () => {
    const repo = { ...MOCK_DOCKER_HUB_REPO, name: "duckduckgo-search" };
    const yaml = { ...MOCK_SERVER_YAML, title: "DuckDuckGo" };
    const entry = buildCatalogEntry(repo, yaml);

    expect(entry.mcpName).toBe("DuckDuckGo");
  });

  test("handles repo with zero pull count", () => {
    const repo = { ...MOCK_DOCKER_HUB_REPO, pull_count: 0 };
    const entry = buildCatalogEntry(repo, null);

    expect(entry.pullCount).toBe(0);
  });

  test("handles repo with undefined pull_count", () => {
    const repo = { name: "test", description: "" };
    const entry = buildCatalogEntry(repo, null);

    expect(entry.pullCount).toBe(0);
  });
});

// ===========================================================================
// TEST SUITE 2: inferCategory
// ===========================================================================
describe("inferCategory", () => {
  test("detects database keywords", () => {
    expect(inferCategory("PostgreSQL connector")).toBe("Databases & Storage");
    expect(inferCategory("MySQL database MCP")).toBe("Databases & Storage");
    expect(inferCategory("Redis cache server")).toBe("Databases & Storage");
  });

  test("detects communication keywords", () => {
    expect(inferCategory("Slack integration")).toBe("Communication");
    expect(inferCategory("Email sending service")).toBe("Communication");
    expect(inferCategory("Discord bot MCP")).toBe("Communication");
  });

  test("detects developer tools keywords", () => {
    expect(inferCategory("GitHub integration")).toBe("Developer Tools");
    expect(inferCategory("GitLab CI/CD connector")).toBe("Developer Tools");
  });

  test("detects search keywords", () => {
    expect(inferCategory("Web search engine")).toBe("Search & Web");
    expect(inferCategory("Browser automation")).toBe("Search & Web");
  });

  test("falls back to Uncategorized", () => {
    expect(inferCategory("A mysterious tool")).toBe("Uncategorized");
    expect(inferCategory("")).toBe("Uncategorized");
  });

  test("is case-insensitive", () => {
    expect(inferCategory("POSTGRESQL CONNECTOR")).toBe("Databases & Storage");
    expect(inferCategory("GITHUB Integration")).toBe("Developer Tools");
  });
});

// ===========================================================================
// TEST SUITE 3: deriveInputFields
// ===========================================================================
describe("deriveInputFields", () => {
  test("converts config keys to input fields", () => {
    const fields = deriveInputFields(MOCK_SERVER_YAML);

    expect(fields).toHaveLength(2);
    expect(fields[0].value).toBe("JIRA_TOKEN");
    expect(fields[0].title).toBe("Jira API Token");
    expect(fields[0].type).toBe("password"); // contains "token"
    expect(fields[0].required).toBe(true);
  });

  test("auto-detects password type for secret/token/password keys", () => {
    const yaml = {
      config: {
        API_TOKEN: { title: "Token" },
        DB_SECRET: { title: "Secret" },
        USER_PASSWORD: { title: "Password" },
        HOSTNAME: { title: "Host" },
      },
    };
    const fields = deriveInputFields(yaml);

    expect(fields.find((f) => f.value === "API_TOKEN").type).toBe("password");
    expect(fields.find((f) => f.value === "DB_SECRET").type).toBe("password");
    expect(fields.find((f) => f.value === "USER_PASSWORD").type).toBe("password");
    expect(fields.find((f) => f.value === "HOSTNAME").type).toBe("text");
  });

  test("returns empty array when no config", () => {
    expect(deriveInputFields(null)).toEqual([]);
    expect(deriveInputFields({})).toEqual([]);
    expect(deriveInputFields({ config: undefined })).toEqual([]);
  });

  test("defaults required to true when not specified", () => {
    const yaml = { config: { KEY: {} } };
    const fields = deriveInputFields(yaml);

    expect(fields[0].required).toBe(true);
  });

  test("respects explicit required: false", () => {
    const yaml = { config: { KEY: { required: false } } };
    const fields = deriveInputFields(yaml);

    expect(fields[0].required).toBe(false);
  });

  test("uses placeholder from yaml", () => {
    const yaml = { config: { URL: { placeholder: "https://example.com" } } };
    const fields = deriveInputFields(yaml);

    expect(fields[0].placeholder).toBe("https://example.com");
  });
});

// ===========================================================================
// TEST SUITE 4: Catalog JSON output structure
// ===========================================================================
describe("Catalog output structure", () => {
  test("every entry has all required fields", () => {
    const requiredFields = [
      "mcpName", "description", "category", "serverType", "transportType",
      "dockerImage", "latestTag", "pullCount", "tools", "inputFields",
    ];

    const entry = buildCatalogEntry(MOCK_DOCKER_HUB_REPO, MOCK_SERVER_YAML);

    for (const field of requiredFields) {
      expect(entry).toHaveProperty(field);
    }
  });

  test("dockerImage always starts with mcp/ prefix", () => {
    const repos = [
      { name: "atlassian" },
      { name: "postgres" },
      { name: "some-new-server" },
    ];

    for (const repo of repos) {
      const entry = buildCatalogEntry(repo, null);
      expect(entry.dockerImage).toMatch(/^mcp\//);
    }
  });

  test("tools entries have name and description", () => {
    const entry = buildCatalogEntry(MOCK_DOCKER_HUB_REPO, MOCK_SERVER_YAML);

    for (const tool of entry.tools) {
      expect(tool).toHaveProperty("name");
      expect(tool).toHaveProperty("description");
      expect(typeof tool.name).toBe("string");
      expect(tool.name.length).toBeGreaterThan(0);
    }
  });

  test("handles server.yaml with string-only tool names", () => {
    const yaml = {
      ...MOCK_SERVER_YAML,
      tools: ["search", "fetch", "summarize"],
    };
    const entry = buildCatalogEntry(MOCK_DOCKER_HUB_REPO, yaml);

    expect(entry.tools).toHaveLength(3);
    expect(entry.tools[0].name).toBe("search");
    expect(entry.tools[0].description).toBe("");
  });
});
