/**
 * Fetch GraphQL Schema from FAO Subgraph
 * 
 * This script uses an introspection query to fetch the complete schema
 * from the FAO subgraph deployed on The Graph Studio.
 * 
 * Usage: node scripts/fetch_schema.js
 */

const SUBGRAPH_URL = "https://api.studio.thegraph.com/query/1718248/fao-interface/0.0.1";

// GraphQL introspection query to get full schema
const INTROSPECTION_QUERY = `
  query IntrospectionQuery {
    __schema {
      queryType { name }
      mutationType { name }
      subscriptionType { name }
      types {
        ...FullType
      }
      directives {
        name
        description
        locations
        args {
          ...InputValue
        }
      }
    }
  }

  fragment FullType on __Type {
    kind
    name
    description
    fields(includeDeprecated: true) {
      name
      description
      args {
        ...InputValue
      }
      type {
        ...TypeRef
      }
      isDeprecated
      deprecationReason
    }
    inputFields {
      ...InputValue
    }
    interfaces {
      ...TypeRef
    }
    enumValues(includeDeprecated: true) {
      name
      description
      isDeprecated
      deprecationReason
    }
    possibleTypes {
      ...TypeRef
    }
  }

  fragment InputValue on __InputValue {
    name
    description
    type {
      ...TypeRef
    }
    defaultValue
  }

  fragment TypeRef on __Type {
    kind
    name
    ofType {
      kind
      name
      ofType {
        kind
        name
        ofType {
          kind
          name
          ofType {
            kind
            name
            ofType {
              kind
              name
              ofType {
                kind
                name
                ofType {
                  kind
                  name
                }
              }
            }
          }
        }
      }
    }
  }
`;

// Simple query to get entity types (more readable output)
const SIMPLE_TYPES_QUERY = `
  query GetEntityTypes {
    __schema {
      types {
        kind
        name
        description
        fields {
          name
          type {
            name
            kind
            ofType {
              name
              kind
            }
          }
        }
      }
    }
  }
`;

// Test query to verify connection
const TEST_QUERY = `
  query TestConnection {
    sales(first: 1) {
      id
      totalAmountRaised
      currentPriceWeiPerToken
    }
    purchaseEvents(first: 3, orderBy: timestamp, orderDirection: desc) {
      id
      buyer
      numTokens
      costWei
      timestamp
    }
  }
`;

async function fetchSchema() {
  console.log("🔍 Fetching schema from FAO Subgraph...");
  console.log(`📍 Endpoint: ${SUBGRAPH_URL}\n`);

  try {
    // First, test the connection with a simple query
    console.log("1️⃣ Testing connection with sample query...");
    const testResponse = await fetch(SUBGRAPH_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ query: TEST_QUERY }),
    });

    if (!testResponse.ok) {
      throw new Error(`HTTP error! status: ${testResponse.status}`);
    }

    const testData = await testResponse.json();

    if (testData.errors) {
      console.log("⚠️ Query errors:", JSON.stringify(testData.errors, null, 2));
    } else {
      console.log("✅ Connection successful!");
      console.log("\n📊 Sample data from subgraph:");
      console.log(JSON.stringify(testData.data, null, 2));
    }

    // Now fetch the schema types
    console.log("\n2️⃣ Fetching schema types...");
    const schemaResponse = await fetch(SUBGRAPH_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ query: SIMPLE_TYPES_QUERY }),
    });

    const schemaData = await schemaResponse.json();

    if (schemaData.errors) {
      console.log("⚠️ Schema query errors:", JSON.stringify(schemaData.errors, null, 2));
      return;
    }

    // Filter to show only entity types (not built-in GraphQL types)
    const entityTypes = schemaData.data.__schema.types.filter(
      (type) =>
        type.kind === "OBJECT" &&
        !type.name.startsWith("__") &&
        !["Query", "Subscription"].includes(type.name) &&
        type.fields
    );

    console.log("\n📋 Entity Types in FAO Subgraph:");
    console.log("=".repeat(50));

    entityTypes.forEach((type) => {
      console.log(`\n📦 ${type.name}`);
      if (type.description) {
        console.log(`   ${type.description}`);
      }
      console.log("   Fields:");
      type.fields.forEach((field) => {
        const typeName = field.type.name || field.type.ofType?.name || field.type.kind;
        console.log(`     - ${field.name}: ${typeName}`);
      });
    });

    // Write full introspection to file
    console.log("\n3️⃣ Fetching full introspection schema...");
    const fullResponse = await fetch(SUBGRAPH_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ query: INTROSPECTION_QUERY }),
    });

    const fullData = await fullResponse.json();

    const fs = await import("fs");
    const outputPath = "./schema_introspection.json";
    fs.writeFileSync(outputPath, JSON.stringify(fullData, null, 2));
    console.log(`\n✅ Full schema saved to: ${outputPath}`);

    // Also create a readable SDL-like output
    const sdlPath = "./schema_readable.txt";
    let sdlOutput = "# FAO Subgraph Schema\n";
    sdlOutput += `# Endpoint: ${SUBGRAPH_URL}\n`;
    sdlOutput += `# Generated: ${new Date().toISOString()}\n\n`;

    entityTypes.forEach((type) => {
      sdlOutput += `type ${type.name} {\n`;
      type.fields.forEach((field) => {
        const typeName = getTypeName(field.type);
        sdlOutput += `  ${field.name}: ${typeName}\n`;
      });
      sdlOutput += `}\n\n`;
    });

    fs.writeFileSync(sdlPath, sdlOutput);
    console.log(`✅ Readable schema saved to: ${sdlPath}`);

  } catch (error) {
    console.error("❌ Error fetching schema:", error.message);

    if (error.cause) {
      console.error("   Cause:", error.cause);
    }
  }
}

function getTypeName(type) {
  if (type.name) return type.name;
  if (type.kind === "NON_NULL") {
    return `${getTypeName(type.ofType)}!`;
  }
  if (type.kind === "LIST") {
    return `[${getTypeName(type.ofType)}]`;
  }
  if (type.ofType) {
    return getTypeName(type.ofType);
  }
  return type.kind;
}

// Run the script
fetchSchema();
