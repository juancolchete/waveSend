import TransactionForm from "./transaction-form"
import { Toaster } from "./components/ui/toaster"

export default function Page() {
  return (
    <div className="min-h-screen flex items-center justify-center p-4 bg-gray-50">
      <TransactionForm />
      <Toaster />
    </div>
  )
}

