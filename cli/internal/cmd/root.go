package cmd

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

var profileFlag string

var rootCmd = &cobra.Command{
	Use:   "fountain",
	Short: "Fountain CLI",
	Long: `Fountain CLI.

Credentials are read from FOUNTAIN_API_KEY env var or ~/.fountain/credentials.
Use FOUNTAIN_PROFILE or --profile to select a non-default profile.`,
	SilenceUsage:  true,
	SilenceErrors: true,
}

func Execute() {
	if err := rootCmd.Execute(); err != nil {
		Fatal(err.Error())
	}
}

func init() {
	rootCmd.PersistentFlags().StringVar(&profileFlag, "profile", "", "credentials profile name")
}

// Fatal prints "fountain: <msg>" to stderr and exits 1.
func Fatal(msg string) {
	fmt.Fprintln(os.Stderr, "fountain: "+msg)
	os.Exit(1)
}

// Fatalf is Fatal with format args.
func Fatalf(format string, a ...any) {
	Fatal(fmt.Sprintf(format, a...))
}
