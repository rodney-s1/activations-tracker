/**
 * BillingMaster Sync API — Lambda handler
 *
 * Routes:
 *   GET  /sync/{node}   → read one node from DynamoDB
 *   PUT  /sync/{node}   → write one node to DynamoDB
 *
 * DynamoDB table: BillingMasterSync
 *   PK: nodeId (String) — e.g. "rate_plan_overrides"
 *   payload (String)    — full JSON blob stored as a string
 *   updatedAt (String)  — ISO timestamp
 *
 * Valid nodes (mirrors the 9 nodes previously on Firebase):
 *   standard_plan_rates, customer_plan_codes, rate_plan_overrides,
 *   serial_filter_rules, imported_csvs, qb_customers,
 *   qb_ignore_keywords, item_price_list, fuel_aliases
 */

import { DynamoDBClient } from '@aws-sdk/client-dynamodb';
import { DynamoDBDocumentClient, GetCommand, PutCommand } from '@aws-sdk/lib-dynamodb';

const TABLE  = process.env.TABLE_NAME ?? 'BillingMasterSync';
const REGION = process.env.AWS_REGION  ?? 'us-east-1';

const ddb = DynamoDBDocumentClient.from(
  new DynamoDBClient({ region: REGION }),
  { marshallOptions: { removeUndefinedValues: true } },
);

const VALID_NODES = new Set([
  'standard_plan_rates',
  'customer_plan_codes',
  'rate_plan_overrides',
  'serial_filter_rules',
  'imported_csvs',
  'qb_customers',
  'qb_ignore_keywords',
  'item_price_list',
  'fuel_aliases',
]);

// CORS headers — app is served from internal.bluearrowtelematics.com
const CORS = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Methods': 'GET,PUT,OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
};

function ok(body) {
  return {
    statusCode: 200,
    headers: { 'Content-Type': 'application/json', ...CORS },
    body: JSON.stringify(body),
  };
}

function err(statusCode, message) {
  return {
    statusCode,
    headers: { 'Content-Type': 'application/json', ...CORS },
    body: JSON.stringify({ error: message }),
  };
}

export async function handler(event) {
  // Handle CORS preflight
  if (event.requestContext?.http?.method === 'OPTIONS') {
    return { statusCode: 204, headers: CORS, body: '' };
  }

  const method = event.requestContext?.http?.method ?? event.httpMethod;
  // path is /sync/{node}
  const pathParams = event.pathParameters ?? {};
  const node = pathParams.node;

  if (!node || !VALID_NODES.has(node)) {
    return err(400, `Invalid node: "${node}". Must be one of: ${[...VALID_NODES].join(', ')}`);
  }

  // ── GET ──────────────────────────────────────────────────────────────────
  if (method === 'GET') {
    try {
      const result = await ddb.send(new GetCommand({
        TableName: TABLE,
        Key: { nodeId: node },
      }));

      if (!result.Item) {
        // Return "null" exactly like Firebase does for missing nodes
        return {
          statusCode: 200,
          headers: { 'Content-Type': 'application/json', ...CORS },
          body: 'null',
        };
      }

      // payload is stored as a JSON string — return it directly
      return {
        statusCode: 200,
        headers: { 'Content-Type': 'application/json', ...CORS },
        body: result.Item.payload,
      };
    } catch (e) {
      console.error('GET error', node, e);
      return err(500, e.message);
    }
  }

  // ── PUT ──────────────────────────────────────────────────────────────────
  if (method === 'PUT') {
    try {
      const body = event.body ?? 'null';
      // Validate it's valid JSON before storing
      JSON.parse(body);

      await ddb.send(new PutCommand({
        TableName: TABLE,
        Item: {
          nodeId:    node,
          payload:   body,
          updatedAt: new Date().toISOString(),
        },
      }));

      return ok({ success: true, node, updatedAt: new Date().toISOString() });
    } catch (e) {
      console.error('PUT error', node, e);
      return err(500, e.message);
    }
  }

  return err(405, `Method ${method} not allowed`);
}
