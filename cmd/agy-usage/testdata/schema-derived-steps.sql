-- The steps DDL matches the schema observed in AGY conversation databases.
-- The row is wholly synthetic and contains no captured identifiers or user content.
CREATE TABLE `steps` (`idx` integer,`step_type` integer NOT NULL DEFAULT 0,`status` integer NOT NULL DEFAULT 0,`has_subtrajectory` numeric NOT NULL DEFAULT false,`metadata` blob,`error_details` blob,`permissions` blob,`task_details` blob,`render_info` blob,`step_payload` blob,`step_format` integer NOT NULL DEFAULT 0,PRIMARY KEY (`idx`));
INSERT INTO steps (idx, step_type, status, metadata, step_payload)
VALUES (1, 132, 3,
  X'0a0808ace4cfaa061000121173796e7468657469632d73657373696f6e',
  X'2a314a2f8a020d08e05d1084fe0218b81720be023a1047656d696e692053796e746865746963420b616e746967726176697479');
