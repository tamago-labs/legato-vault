import { type ClientSchema, a, defineData } from "@aws-amplify/backend";

const schema = a.schema({
  User: a
    .model({
      username: a.string().required(),
      image: a.url(),
      markets: a.hasMany('Market', "managerId"),
      comments: a.hasMany('Comment', "userId"),
      positions: a.hasMany('Position', "userId"),
      role: a.enum(["USER", "MANAGER", "ADMIN"])
    })
    .authorization((allow) => [allow.publicApiKey()]),
  Market: a
    .model({
      managerId: a.id().required(),
      manager: a.belongsTo('User', "managerId"),
      onchainId: a.integer(),
      title: a.string().required(),
      description: a.string(),
      chains: a.string().array(),
      images: a.string().array(),
      resource: a.hasOne('Resource', "marketId"),
      category: a.string(),
      tags: a.string().array(),
      currency: a.string(),
      maxBet: a.float(),
      minBet: a.float(),
      onchainCreatedTime: a.timestamp(),
      onchainRoundInterval: a.integer(),
      betPoolAmount: a.float(),
      comments: a.hasMany('Comment', "marketId"),
      positions: a.hasMany('Position', "marketId"),
      rounds: a.hasMany('Round', "marketId"),
      totalOutcomes: a.integer()
    })
    .authorization((allow) => [allow.publicApiKey()]),
  Comment: a.model({
    marketId: a.id().required(),
    userId: a.id().required(),
    user: a.belongsTo('User', "userId"),
    market: a.belongsTo('Market', "marketId"),
    rating: a.integer(),
    content: a.string()
  }).authorization((allow) => [allow.publicApiKey()]),
  Position: a.model({
    marketId: a.id().required(),
    market: a.belongsTo('Market', "marketId"),
    userId: a.id().required(),
    user: a.belongsTo('User', "userId"),
    roundId: a.integer(),
    onchainId: a.integer(),
    chain: a.string(),
    predictedOutcome: a.integer(),
    betAmount: a.integer(),
    hidden: a.boolean(),
    status: a.enum(["PENDING", "WIN", "LOSE", "CANCELLED"]),
    walletAddress: a.string()
  }).authorization((allow) => [allow.publicApiKey()]),
  Round: a.model({
    marketId: a.id().required(),
    market: a.belongsTo('Market', "marketId"),
    onchainId: a.integer(),
    totalBetAmount: a.float(),
    totalPaidAmount: a.float(),
    totalDisputedAmount: a.float(),
    weight: a.float(),
    outcomes:  a.hasMany('Outcome', "roundId"),
    winningOutcomes: a.integer().array(),
    disputedOutcomes: a.integer().array(),
    status: a.enum(["PENDING", "FINALIZED", "RESOLVED"]),
    finalizedTimestamp: a.timestamp(),
    resolvedTimestamp: a.timestamp(),
    agentName: a.string(),
    agentMessages: a.json().array(),
    agentConfig: a.json(),
  }).authorization((allow) => [allow.publicApiKey()]),
  Outcome: a.model({
    roundId: a.id().required(),
    round: a.belongsTo('Round', "roundId"),
    onchainId: a.integer(),
    totalBetAmount: a.float(),
    weight: a.float(),
    title: a.string(),
    resolutionDate: a.timestamp(),
    status: a.enum(["PENDING", "WIN", "LOSE", "CANCELLED"]),
    crawledDataAtCreated: a.string(),
    result: a.string()
  }).authorization((allow) => [allow.publicApiKey()]),
  Resource: a.model({
    marketId: a.id().required(),
    market: a.belongsTo('Market', "marketId"),
    name: a.string(),
    url: a.string(),
    category: a.string(),
    crawledData: a.string(),
    lastCrawledAt: a.timestamp()
  }).authorization((allow) => [allow.publicApiKey()]),
});

export type Schema = ClientSchema<typeof schema>;

export const data = defineData({
  schema,
  authorizationModes: {
    defaultAuthorizationMode: "apiKey",
    apiKeyAuthorizationMode: {
      expiresInDays: 30,
    },
  },
});