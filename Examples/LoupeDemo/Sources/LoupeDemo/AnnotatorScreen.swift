#if os(macOS)
import SwiftUI
import LoupeCore

/// The product being annotated: a small stock admin with three things wrong with it
/// on purpose.
///
/// Every button here makes a real request to the local stub, so the trace Loupe
/// captures is the app's own network activity rather than a fixture.
struct AnnotatorScreen: View {
    let server: StubServer

    @State private var query = ""
    @State private var results: [Seed.Product] = Seed.products
    @State private var lastStatus: String?
    @State private var orderName = ""
    @State private var orderError: String?

    var body: some View {
        HSplitView {
            catalogue
            basket
        }
        .task { await search("") }
    }

    // MARK: - Catalogue

    private var catalogue: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stock").font(.title2).bold()

            HStack {
                TextField("Search stock", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("search.field")
                    .onSubmit { Task { await search(query) } }

                Button("Search") { Task { await search(query) } }
                    .accessibilityIdentifier("search.submit")

                // The seeded bug: clearing the search fires a request that fails,
                // and the old results stay on screen.
                Button("Clear") {
                    query = ""
                    Task { await search("") }
                }
                .accessibilityIdentifier("search.clear")
            }

            if let lastStatus {
                Text(lastStatus)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("search.status")
            }

            List(results) { product in
                HStack {
                    VStack(alignment: .leading) {
                        Text(product.name)
                        Text(product.price).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    // The second seeded problem: out of stock reads the same as in
                    // stock unless you look closely at a grey number.
                    Text("\(product.stock)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
            }
            .accessibilityIdentifier("search.results")
            .frame(minHeight: 260)
        }
        .padding(16)
        .frame(minWidth: 460)
    }

    // MARK: - Basket

    private var basket: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Basket").font(.title2).bold()

            // The third seeded problem: an empty state with nothing to do next.
            VStack(spacing: 6) {
                Text("Your basket is empty")
                Text("0 items")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 120)
            .background(Color.secondary.opacity(0.06))
            .accessibilityIdentifier("cart.empty")

            Divider()

            Text("Place an order").font(.headline)
            TextField("Customer name", text: $orderName)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("order.name")

            Button("Place order") { Task { await placeOrder() } }
                .accessibilityIdentifier("order.submit")

            if let orderError {
                Text(orderError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("order.error")
            }

            Spacer()

            Text("⌥⌘L to annotate")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(minWidth: 320)
    }

    // MARK: - Real requests

    private func search(_ term: String) async {
        var components = URLComponents(url: server.baseURL.appendingPathComponent("v2/search"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "q", value: term)]
        guard let url = components.url else { return }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            lastStatus = "GET /v2/search?q=\(term) → \(code)"

            guard code == 200 else {
                // Deliberately keeps the stale page. This is the bug the demo exists
                // to have someone find.
                LogRecorder.shared.error("kept the last good page after a \(code)",
                                         subsystem: "search")
                return
            }
            results = decode(data)
        } catch {
            LogRecorder.shared.error("search failed: \(error.localizedDescription)",
                                     subsystem: "search")
        }
    }

    private func placeOrder() async {
        var request = URLRequest(url: server.baseURL.appendingPathComponent("v2/orders"))
        request.httpMethod = "POST"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code >= 400 {
                orderError = "Something went wrong."   // deliberately unhelpful
                LogRecorder.shared.error("POST /v2/orders → \(code) payment provider timed out",
                                         subsystem: "orders")
            }
        } catch {
            orderError = "Something went wrong."
        }
    }

    /// Small enough that a hand-rolled read beats defining mirrored Codable types.
    private func decode(_ data: Data) -> [Seed.Product] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]] else { return [] }
        return items.compactMap { item in
            guard let id = item["id"] as? Int,
                  let name = item["name"] as? String,
                  let price = item["price"] as? String,
                  let stock = item["stock"] as? Int else { return nil }
            return Seed.Product(id: id, name: name, price: price, stock: stock)
        }
    }
}
#endif
