import Foundation

enum OpenAPIDocument {
    static let data = Data(spec.utf8)

    private static let spec = #"""
    {
      "openapi": "3.1.0",
      "info": {
        "title": "vphoned API",
        "version": "1.0.0",
        "description": "Guest API over VSOCK 1339. vphone-vm can forward it to an opt-in host HTTP listener. JSON operations are also available as WebSocket requests on /v1/events."
      },
      "servers": [{"url": "/"}],
      "paths": {
        "/v1/health": {"get": {"operationId": "health", "responses": {"200": {"description": "Daemon is running"}}}},
        "/v1/device": {"get": {"operationId": "device.snapshot", "responses": {"200": {"$ref": "#/components/responses/Result"}}}},
        "/v1/device/screen": {"get": {"operationId": "device.screen", "responses": {"200": {"$ref": "#/components/responses/Result"}}}},
        "/v1/apps": {"get": {"operationId": "apps.list", "responses": {"200": {"$ref": "#/components/responses/Result"}}}},
        "/v1/apps/launch": {"post": {"operationId": "apps.launch", "requestBody": {"$ref": "#/components/requestBodies/Parameters"}, "responses": {"200": {"$ref": "#/components/responses/Result"}}}},
        "/v1/apps/terminate": {"post": {"operationId": "apps.terminate", "requestBody": {"$ref": "#/components/requestBodies/Parameters"}, "responses": {"200": {"$ref": "#/components/responses/Result"}}}},
        "/v1/apps/foreground": {"get": {"operationId": "apps.foreground", "responses": {"200": {"$ref": "#/components/responses/Result"}}}},
        "/v1/apps/open-url": {"post": {"operationId": "apps.open_url", "requestBody": {"$ref": "#/components/requestBodies/Parameters"}, "responses": {"200": {"$ref": "#/components/responses/Result"}}}},
        "/v1/apps/install": {"post": {"operationId": "apps.install", "requestBody": {"$ref": "#/components/requestBodies/Parameters"}, "responses": {"200": {"$ref": "#/components/responses/Result"}}}},
        "/v1/input/touch": {"post": {"operationId": "input.touch", "requestBody": {"$ref": "#/components/requestBodies/Parameters"}, "responses": {"200": {"$ref": "#/components/responses/Result"}}}},
        "/v1/input/hid": {"post": {"operationId": "input.hid", "requestBody": {"$ref": "#/components/requestBodies/Parameters"}, "responses": {"200": {"$ref": "#/components/responses/Result"}}}},
        "/v1/location": {
          "get": {"operationId": "location.current", "responses": {"200": {"$ref": "#/components/responses/Result"}}},
          "put": {"operationId": "location.set", "requestBody": {"$ref": "#/components/requestBodies/Parameters"}, "responses": {"200": {"$ref": "#/components/responses/Result"}}},
          "delete": {"operationId": "location.clear", "responses": {"200": {"$ref": "#/components/responses/Result"}}}
        },
        "/v1/developer-mode": {"get": {"operationId": "developer_mode.status", "responses": {"200": {"$ref": "#/components/responses/Result"}}}},
        "/v1/developer-mode/enable": {"post": {"operationId": "developer_mode.enable", "responses": {"200": {"$ref": "#/components/responses/Result"}}}},
        "/v1/low-power-mode": {
          "get": {"operationId": "power.low_power_mode", "responses": {"200": {"$ref": "#/components/responses/Result"}}},
          "put": {"operationId": "power.low_power_mode", "requestBody": {"$ref": "#/components/requestBodies/Parameters"}, "responses": {"200": {"$ref": "#/components/responses/Result"}}}
        },
        "/v1/clipboard": {
          "get": {"operationId": "clipboard.get", "responses": {"200": {"$ref": "#/components/responses/Result"}}},
          "put": {"operationId": "clipboard.set", "requestBody": {"$ref": "#/components/requestBodies/Parameters"}, "responses": {"200": {"$ref": "#/components/responses/Result"}}}
        },
        "/v1/clipboard/image": {
          "get": {"operationId": "clipboard.image.download", "responses": {"200": {"description": "PNG image"}}},
          "put": {"operationId": "clipboard.image.upload", "requestBody": {"required": true, "content": {"application/octet-stream": {"schema": {"type": "string", "format": "binary"}}}}, "responses": {"200": {"description": "Clipboard image set"}}}
        },
        "/v1/files": {"get": {"operationId": "files.list", "parameters": [{"name": "path", "in": "query", "required": true, "schema": {"type": "string"}}], "responses": {"200": {"$ref": "#/components/responses/Result"}}}},
        "/v1/files/content": {
          "get": {"operationId": "files.download", "parameters": [{"$ref": "#/components/parameters/FilePath"}], "responses": {"200": {"description": "File bytes", "content": {"application/octet-stream": {"schema": {"type": "string", "format": "binary"}}}}}},
          "put": {"operationId": "files.upload", "parameters": [{"$ref": "#/components/parameters/FilePath"}, {"name": "mode", "in": "query", "schema": {"type": "string", "default": "644", "pattern": "^0?[0-7]{1,3}$"}}], "requestBody": {"required": true, "content": {"application/octet-stream": {"schema": {"type": "string", "format": "binary"}}}}, "responses": {"200": {"description": "File stored"}}}
        },
        "/v1/files/mkdir": {"post": {"operationId": "files.mkdir", "requestBody": {"$ref": "#/components/requestBodies/Parameters"}, "responses": {"200": {"$ref": "#/components/responses/Result"}}}},
        "/v1/files/remove": {"post": {"operationId": "files.remove", "requestBody": {"$ref": "#/components/requestBodies/Parameters"}, "responses": {"200": {"$ref": "#/components/responses/Result"}}}},
        "/v1/files/rename": {"post": {"operationId": "files.rename", "requestBody": {"$ref": "#/components/requestBodies/Parameters"}, "responses": {"200": {"$ref": "#/components/responses/Result"}}}},
        "/v1/settings/get": {"post": {"operationId": "settings.get", "requestBody": {"$ref": "#/components/requestBodies/Parameters"}, "responses": {"200": {"$ref": "#/components/responses/Result"}}}},
        "/v1/settings/set": {"post": {"operationId": "settings.set", "requestBody": {"$ref": "#/components/requestBodies/Parameters"}, "responses": {"200": {"$ref": "#/components/responses/Result"}}}},
        "/v1/keychain": {
          "get": {"operationId": "keychain.list", "responses": {"200": {"$ref": "#/components/responses/Result"}}},
          "post": {"operationId": "keychain.add", "requestBody": {"$ref": "#/components/requestBodies/Parameters"}, "responses": {"200": {"$ref": "#/components/responses/Result"}}}
        },
        "/v1/rpc": {"post": {"operationId": "rpc", "requestBody": {"required": true, "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Request"}}}}, "responses": {"200": {"$ref": "#/components/responses/Result"}}}},
        "/v1/events": {"get": {"operationId": "websocketEvents", "description": "Upgrade to WebSocket. Send Request objects and receive Response or Event objects.", "responses": {"101": {"description": "WebSocket upgrade"}, "426": {"description": "Upgrade required"}}}}
      },
      "components": {
        "parameters": {"FilePath": {"name": "path", "in": "query", "required": true, "schema": {"type": "string", "description": "Absolute guest path"}}},
        "schemas": {
          "Request": {"type": "object", "required": ["method"], "properties": {"id": {"oneOf": [{"type": "string"}, {"type": "integer"}]}, "method": {"type": "string"}, "params": {"type": "object", "additionalProperties": true}}},
          "Response": {"type": "object", "required": ["type", "id"], "properties": {"type": {"const": "response"}, "id": {}, "result": {"type": "object", "additionalProperties": true}, "error": {"$ref": "#/components/schemas/Error"}}},
          "Event": {"type": "object", "required": ["type", "event", "data"], "properties": {"type": {"const": "event"}, "event": {"type": "string"}, "data": {"type": "object", "additionalProperties": true}}},
          "Error": {"type": "object", "required": ["code", "message"], "properties": {"code": {"type": "string"}, "message": {"type": "string"}}}
        },
        "requestBodies": {
          "Parameters": {"content": {"application/json": {"schema": {"type": "object", "additionalProperties": true}}}}
        },
        "responses": {"Result": {"description": "A Response envelope with result or error", "content": {"application/json": {"schema": {"$ref": "#/components/schemas/Response"}}}}}
      },
      "x-websocket": {"path": "/v1/events", "request": {"$ref": "#/components/schemas/Request"}, "messages": [{"$ref": "#/components/schemas/Response"}, {"$ref": "#/components/schemas/Event"}]}
    }
    """#
}
